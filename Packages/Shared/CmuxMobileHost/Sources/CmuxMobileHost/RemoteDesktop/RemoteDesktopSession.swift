import CmuxBrowserStream
import CmuxLink
import CmuxMobileLink
import CmuxMobileWire
import CmuxRemoteDesktop
import Foundation

/// One served `rd` channel (c3-rd.md 2 to 8): `channel.opened`, consent,
/// the target, the video pump with view labels, the viewer-to-host loop,
/// the datagram lane, the host indicator and its Stop.
actor RemoteDesktopSession {
    enum End: Sendable {
        /// The phone closed the channel, or the link ended (revocation included).
        case phone
        case stopped
        case consentDenied
        case target(DesktopEndReason)
        case failed(code: String, message: String)
    }

    private let channel: MobileChannel
    private let params: RemoteDesktopChannelParams
    private let install: String
    private let gate: MobileSessionGate
    private let handler: RemoteDesktopChannelHandler
    private let fit = DesktopViewFit()

    private var info: DesktopTargetInfo
    private var view: DesktopView
    private var previousStream: UInt16
    private var hostSeq = DesktopView.hostSeqBase
    private var mode: DesktopMode = .view
    private var accessibility = false
    private var controlConsented = false
    private var live = false
    private var target: (any RemoteDesktopTarget)?
    private var indicatorHandle: (any RemoteDesktopIndicatorHandle)?

    private var lane: MobileDatagramLane?
    private var packetizer = RdPacketizer(maxDatagram: RdPacketizer.streamDatagram)
    private var bitrate = BrowserBitrateController()
    private var frameNumber: UInt32 = 0
    private var lastAppliedInput: UInt32 = 0
    private var sentSinceFeedback = 0
    private var finished = false
    private var phoneGone = false
    private var tasks: [Task<Void, Never>] = []
    private var consentTask: Task<Bool, Never>?
    private let ends: AsyncStream<End>
    private let endsContinuation: AsyncStream<End>.Continuation

    init(channel: MobileChannel, params: RemoteDesktopChannelParams, info: DesktopTargetInfo, install: String,
         gate: MobileSessionGate, handler: RemoteDesktopChannelHandler) {
        self.channel = channel
        self.params = params
        self.info = info
        self.install = install
        self.gate = gate
        self.handler = handler
        view = DesktopViewFit().initialView(target: info, screen: params.screen)
        previousStream = view.stream
        (ends, endsContinuation) = AsyncStream.makeStream(of: End.self, bufferingPolicy: .bufferingOldest(8))
    }

    func run() async {
        accessibility = info.kind == .vnc ? true : await handler.permissions.isGranted(.accessibility)
        mode = params.mode == .control && accessibility ? .control : .view
        let displays = info.kind == .display ? await handler.sources.displays() : []
        var caps = ["view"]
        if handler.policy.clipboard { caps.append("clipboard") }
        if info.kind == .display { caps.append("displays") }
        if info.kind != .vnc { caps.append("windows") }
        let opened = RemoteDesktopChannelOpened(datagramChannel: channel.id, target: info, view: view, displays: displays,
                                                mode: mode, cursor: info.kind == .vnc ? .inVideo : .local, caps: caps)
        let ok = ChannelOpenedFrame(channel: channel.id, window: 1 << 20, params: opened.params, resumed: false)
        guard (try? await channel.send(frame: .channelOpened(ok))) != nil else {
            await channel.abort()
            return
        }
        if params.mode == .control, !accessibility {
            await send(.modeApplied(mode: .view, reason: RemoteDesktopPermission.accessibility.rawValue))
        }
        tasks.append(Task { await self.receiveLoop() })
        tasks.append(Task { await self.pumpLanes() })

        if handler.policy.consent == .ask {
            await send(.state(.waitingConsent, reason: nil))
            let ask = Task { await self.askConsent(mode: self.mode) }
            consentTask = ask
            guard await ask.value, !finished else {
                await teardown(phoneGone ? .phone : .consentDenied)
                return
            }
            controlConsented = mode == .control
        } else {
            controlConsented = true
        }
        guard !finished else {
            await teardown(.phone)
            return
        }
        let opening: any RemoteDesktopTarget
        do {
            opening = try await handler.sources.open(RemoteDesktopOpenRequest(target: params.target, install: install, region: view.rect))
        } catch let error as RemoteDesktopSourceError {
            await teardown(.failed(code: error.code, message: "\(error)"))
            return
        } catch {
            await teardown(.failed(code: "rd.unavailable", message: "\(error)"))
            return
        }
        target = opening
        guard !finished else {
            await teardown(.phone)
            return
        }
        let handle = await handler.indicator.begin(RemoteDesktopIndicatorSession(install: install, target: info, mode: mode))
        indicatorHandle = handle
        tasks.append(Task {
            for await _ in handle.stopRequests {
                self.end(.stopped)
                return
            }
        })
        tasks.append(Task { await self.pumpTargetEvents(opening) })
        live = true
        if info.kind != .vnc { await send(.state(.live, reason: nil)) }
        await opening.video.requestKeyframe()
        tasks.append(Task { await self.pumpVideo(opening) })
        var cause = End.phone
        for await end in ends {
            cause = end
            break
        }
        await teardown(cause)
    }

    private func end(_ cause: End) {
        if case .phone = cause {
            phoneGone = true
            consentTask?.cancel()
        }
        endsContinuation.yield(cause)
    }

    // MARK: Consent

    private func askConsent(mode: DesktopMode) async -> Bool {
        let request = RemoteDesktopConsentRequest(install: install, target: info, mode: mode)
        let consent = handler.consent
        let clock = handler.clock
        let timeout = handler.policy.consentTimeout
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await consent.request(request) }
            group.addTask {
                do {
                    try await clock.sleep(for: timeout)
                    return false
                } catch {
                    return nil
                }
            }
            defer { group.cancelAll() }
            while let result = await group.next() {
                if let result { return result && !Task.isCancelled }
                if Task.isCancelled { return false }
            }
            return false
        }
    }

    // MARK: Host to viewer

    private func pumpVideo(_ target: any RemoteDesktopTarget) async {
        let source = target.video
        while !finished, !Task.isCancelled {
            let request = BrowserFrameRequest(pixelWidth: view.pixelWidth, pixelHeight: view.pixelHeight,
                                              bitrate: bitrate.target, maxFPS: handler.policy.maxFPS)
            let encoded: BrowserEncodedFrame?
            do {
                encoded = try await source.nextFrame(request)
            } catch {
                encoded = nil
            }
            guard !finished else { return }
            guard let encoded else {
                // ScreenCaptureKit stops the stream when Screen Recording is revoked.
                let revoked = info.kind != .vnc ? await !handler.permissions.isGranted(.screenRecording) : false
                end(.target(revoked ? .permissionRevoked : .targetGone))
                return
            }
            await send(encoded)
        }
    }

    private func send(_ encoded: BrowserEncodedFrame) async {
        let previous = frameNumber
        frameNumber += 1
        let body = RdFrameBody(captureMicros: encoded.captureMicros,
                               refFrame: encoded.isKeyframe || previous == 0 ? RdFrameBody.refNone : previous,
                               accessUnit: encoded.accessUnit)
        // A frame captured before the last view change still shows the old view.
        let matchesView = encoded.pixelWidth == view.pixelWidth && encoded.pixelHeight == view.pixelHeight
        packetizer.stream = matchesView ? view.stream : previousStream
        let lane = self.lane
        packetizer.setMaxDatagram(lane == nil ? RdPacketizer.streamDatagram : RdPacketizer.laneDatagram)
        guard let datagrams = try? packetizer.packetize(frame: frameNumber, flags: encoded.isKeyframe ? .keyframe : [],
                                                        body: body) else {
            await target?.video.requestKeyframe()
            return
        }
        sentSinceFeedback += datagrams.count
        if let lane {
            for datagram in datagrams {
                guard await lane.send(DesktopPayload.encodedDatagram(datagram)) else { break }
            }
            return
        }
        let started = handler.clock.now
        for datagram in datagrams {
            guard (try? await channel.send(binary: DesktopPayload.encodedDatagram(datagram),
                                           flags: encoded.isKeyframe ? .keyframe : [])) != nil else { return }
        }
        if handler.clock.now - started > Duration.seconds(1) / handler.policy.maxFPS * 2 { bitrate.sendStalled() }
    }

    private func pumpTargetEvents(_ target: any RemoteDesktopTarget) async {
        for await event in await target.events() {
            guard !finished else { return }
            switch event {
            case .resized(let info):
                self.info = info
                hostSeq &+= 1
                if hostSeq < DesktopView.hostSeqBase { hostSeq = DesktopView.hostSeqBase }
                let fitted = fit.initialView(target: info, screen: params.screen)
                await apply(DesktopView(seq: hostSeq, rect: fitted.rect, pixelWidth: fitted.pixelWidth,
                                        pixelHeight: fitted.pixelHeight), announceTarget: true)
            case .authRequired:
                await send(.state(.authRequired, reason: "vnc"))
            case .live:
                await send(.state(.live, reason: nil))
            case .paused(let reason):
                await send(.state(.paused, reason: reason))
            case .clipboard(let text):
                if handler.policy.clipboard { await send(.clipboard(seq: nil, text: text)) }
            case .ended(let reason):
                end(.target(reason))
                return
            }
        }
    }

    /// Makes `next` the current view: crops the target, labels later
    /// frames with its stream, asks for a keyframe, tells the phone.
    private func apply(_ next: DesktopView, announceTarget: Bool) async {
        try? await target?.setRegion(next.rect)
        if next.stream != view.stream { previousStream = view.stream }
        view = next
        await target?.video.requestKeyframe()
        if announceTarget { await send(.target(info)) }
        await send(.viewApplied(next))
    }

    private func pumpLanes() async {
        for await lane in await channel.datagramLanes() {
            self.lane = lane
            while let data = await lane.receive() {
                guard let payload = try? DesktopPayload(record: data) else { continue }
                await handle(payload)
            }
            if self.lane === lane { self.lane = nil }
        }
    }

    private func send(_ message: DesktopMessage) async {
        guard let data = try? DesktopPayload.control(message).encoded() else { return }
        try? await channel.send(binary: data)
    }

    // MARK: Viewer to host

    private func receiveLoop() async {
        defer { end(.phone) }
        while !finished {
            switch await channel.receive() {
            case .closed:
                return
            case .gap:
                continue
            case .json(let value):
                // The only JSON a phone sends after open is channel.close.
                if case .channelClose? = try? MobileFrame(value: value) { return }
            case .binary(let data, _):
                guard let payload = try? DesktopPayload(record: data) else {
                    end(.failed(code: "proto.bad_record", message: "not an rd stream frame"))
                    return
                }
                guard await handle(payload) else { return }
            }
        }
    }

    /// Returns false when the channel must close.
    @discardableResult
    private func handle(_ payload: DesktopPayload) async -> Bool {
        switch payload {
        case .datagram(let header, let body):
            switch header.kind {
            case .input: return await applyInput(body)
            case .feedback: await applyFeedback(body)
            default: break
            }
        case .control(let message):
            await apply(message)
        case .otherControl:
            break
        }
        return true
    }

    private func applyInput(_ body: Data) async -> Bool {
        guard let packet = try? RdInputPacket(decoding: body) else {
            end(.failed(code: "proto.bad_record", message: "bad input packet"))
            return false
        }
        for (offset, event) in packet.events.enumerated() {
            let seq = packet.firstSeq &+ UInt32(offset)
            if seq <= lastAppliedInput { continue }
            guard seq == lastAppliedInput + 1 else {
                end(.failed(code: "validation.invalid", message: "input seq \(seq) after \(lastAppliedInput)"))
                return false
            }
            lastAppliedInput = seq
            // View mode, consent pending, or a revoked device: nothing reaches the target.
            guard live, mode == .control, let target, await gate.isOpen else { continue }
            await target.apply(event)
        }
        let ack = RdDatagramHeader(kind: .inputAck)
        if let data = try? DesktopPayload.datagram(ack, RdInputAck(appliedSeq: lastAppliedInput).encoded).encoded() {
            try? await channel.send(binary: data)
        }
        return true
    }

    private func applyFeedback(_ body: Data) async {
        guard let feedback = try? RdFeedback(decoding: body) else { return }
        let loss: Double
        if lane != nil, sentSinceFeedback > 0, !feedback.arrivals.isEmpty {
            loss = max(0, 1 - Double(feedback.arrivals.count) / Double(sentSinceFeedback))
        } else {
            loss = 0
        }
        sentSinceFeedback = 0
        bitrate.feedback(lossFraction: loss, needRecovery: feedback.needRecovery, now: handler.clock.now)
        if feedback.needRecovery { await target?.video.requestKeyframe() }
    }

    private func apply(_ message: DesktopMessage) async {
        switch message {
        case .view(let request):
            guard request.seq < DesktopView.hostSeqBase else { return }
            await apply(fit.clamp(request, to: info), announceTarget: false)
        case .select(let display):
            await select(display: display)
        case .windowsList:
            guard info.kind != .vnc, await gate.isOpen else { return }
            await send(.windows(await handler.sources.windows()))
        case .mode(let requested):
            tasks.append(Task { await self.changeMode(requested) })
        case .clipboardPush(_, let text):
            guard handler.policy.clipboard, live, mode == .control, let target, await gate.isOpen else { return }
            await target.pushClipboard(text)
        case .clipboardPull(let seq):
            guard handler.policy.clipboard, live, let target, await gate.isOpen else { return }
            await send(.clipboard(seq: seq, text: await target.readClipboard() ?? ""))
        case .auth(let password):
            guard info.kind == .vnc, let target, await gate.isOpen else { return }
            await target.authenticate(password: password)
        case .viewApplied, .target, .windows, .modeApplied, .clipboard, .state, .ended:
            break
        }
    }

    private func select(display: UInt32) async {
        guard info.kind == .display, live, await gate.isOpen,
              let next = try? await handler.sources.describe(.display(display)) else { return }
        let fitted = fit.initialView(target: next, screen: params.screen)
        let opened: any RemoteDesktopTarget
        do {
            opened = try await handler.sources.open(RemoteDesktopOpenRequest(target: .display(display), install: install,
                                                                            region: fitted.rect))
        } catch {
            return
        }
        guard !finished else {
            await opened.close()
            return
        }
        let old = target
        target = opened
        info = next
        await old?.close()
        tasks.append(Task { await self.pumpTargetEvents(opened) })
        tasks.append(Task { await self.pumpVideo(opened) })
        hostSeq &+= 1
        if hostSeq < DesktopView.hostSeqBase { hostSeq = DesktopView.hostSeqBase }
        await apply(DesktopView(seq: hostSeq, rect: fitted.rect, pixelWidth: fitted.pixelWidth, pixelHeight: fitted.pixelHeight),
                    announceTarget: true)
    }

    private func changeMode(_ requested: DesktopMode) async {
        guard !finished, await gate.isOpen else { return }
        if requested == .view {
            mode = .view
            await send(.modeApplied(mode: .view, reason: nil))
            await indicatorHandle?.update(mode: .view)
            return
        }
        guard accessibility else {
            await send(.modeApplied(mode: .view, reason: RemoteDesktopPermission.accessibility.rawValue))
            return
        }
        if handler.policy.consent == .ask, !controlConsented {
            guard await askConsent(mode: .control), !finished else {
                await send(.modeApplied(mode: mode, reason: "consent_denied"))
                return
            }
            controlConsented = true
        }
        mode = .control
        await send(.modeApplied(mode: .control, reason: nil))
        await indicatorHandle?.update(mode: .control)
    }

    // MARK: Teardown

    private func teardown(_ cause: End) async {
        guard !finished else { return }
        finished = true
        live = false
        consentTask?.cancel()
        let target = self.target
        self.target = nil
        await target?.close()
        await indicatorHandle?.end()
        switch cause {
        case .phone:
            await channel.close()
        case .stopped:
            await send(.ended(reason: DesktopEndReason.stoppedByHost.rawValue))
            await channel.close(code: "rd.stopped_by_host", message: "stopped on the Mac")
        case .consentDenied:
            await send(.ended(reason: DesktopEndReason.consentDenied.rawValue))
            await channel.close(code: "rd.consent_denied", message: "denied on the Mac")
        case .target(let reason):
            await send(.ended(reason: reason.rawValue))
            await channel.close(code: "rd.\(reason.rawValue)", message: "the desktop ended")
        case .failed(let code, let message):
            await send(.ended(reason: code))
            await channel.close(code: code, message: message)
        }
        endsContinuation.finish()
        for task in tasks { task.cancel() }
        await lane?.close()
        // A pump stuck on link credit must not hold the session.
        await channel.abort()
        for task in tasks { await task.value }
        tasks.removeAll()
    }
}
