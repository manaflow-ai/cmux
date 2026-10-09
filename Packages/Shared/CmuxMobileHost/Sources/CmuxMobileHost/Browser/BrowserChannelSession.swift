import CmuxMobileLink
import CmuxBrowserStream
import CmuxLink
import CmuxMobileLink
import CmuxMobileWire
import Foundation

/// One served browser channel: the video pump, the page-event pump, the
/// viewer-to-host loop and the datagram lane (c2-browser-stream.md 2 to 4).
actor BrowserChannelSession {
    static let caps = ["navigate", "clipboard"]
    static let maxScale = 8.0

    private let channel: MobileChannel
    private let attachment: any BrowserPageAttachment
    private let gate: MobileSessionGate
    private let policy: BrowserNavigationPolicy
    private let clock: LinkClock

    private var screen: RbScreenInfo
    private var geometry = BrowserPageGeometry(cssWidth: 1, cssHeight: 1, backingScale: 1)
    private var size = BrowserEncodeSize(pixelWidth: 2, pixelHeight: 2)
    private var bitrate = BrowserBitrateController()
    private var packetizer = RdPacketizer(maxDatagram: RdPacketizer.streamDatagram)
    private var lane: MobileDatagramLane?
    private var frameNumber: UInt32 = 0
    private var lastAppliedInput: UInt32 = 0
    private var sentSinceFeedback = 0
    private var finished = false

    init(channel: MobileChannel, params: BrowserChannelParams, attachment: any BrowserPageAttachment,
         gate: MobileSessionGate, policy: BrowserNavigationPolicy, clock: LinkClock) {
        self.channel = channel
        self.attachment = attachment
        self.gate = gate
        self.policy = policy
        self.clock = clock
        screen = params.screen
    }

    func run() async {
        geometry = await attachment.geometry
        resize()
        let opened = BrowserChannelOpened(datagramChannel: channel.id, encoder: .h264, width: UInt32(size.pixelWidth),
                                          height: UInt32(size.pixelHeight), pageWidth: geometry.cssWidth,
                                          pageHeight: geometry.cssHeight,
                                          caps: policy.allowsNavigation ? Self.caps : ["clipboard"])
        let ok = ChannelOpenedFrame(channel: channel.id, window: 1 << 20, params: opened.params, resumed: false)
        guard (try? await channel.send(frame: .channelOpened(ok))) != nil else {
            await attachment.detach()
            await channel.abort()
            return
        }
        await attachment.video.requestKeyframe()
        await sendRb(.state(.live))
        let video = Task { await self.pumpVideo() }
        let events = Task { await self.pumpEvents() }
        let lanes = Task { await self.pumpLanes() }
        await receiveLoop()
        finished = true
        video.cancel()
        events.cancel()
        lanes.cancel()
        await lane?.close()
        await attachment.detach()
        // A pump stuck on link credit must not hold the session.
        await channel.abort()
        _ = await (video.value, events.value, lanes.value)
    }

    // MARK: Host to viewer

    private func pumpVideo() async {
        let source = attachment.video
        while !finished, !Task.isCancelled {
            let request = BrowserFrameRequest(pixelWidth: size.pixelWidth, pixelHeight: size.pixelHeight,
                                              bitrate: bitrate.target, maxFPS: Int(min(screen.refreshHz, 60)))
            guard let encoded = try? await source.nextFrame(request), !finished else { return }
            await send(encoded)
        }
    }

    private func send(_ encoded: BrowserEncodedFrame) async {
        let previous = frameNumber
        frameNumber += 1
        let body = RdFrameBody(captureMicros: encoded.captureMicros,
                               refFrame: encoded.isKeyframe || previous == 0 ? RdFrameBody.refNone : previous,
                               accessUnit: encoded.accessUnit)
        let lane = self.lane
        packetizer.setMaxDatagram(lane == nil ? RdPacketizer.streamDatagram : RdPacketizer.laneDatagram)
        guard let datagrams = try? packetizer.packetize(frame: frameNumber, flags: encoded.isKeyframe ? .keyframe : [],
                                                        body: body) else {
            await attachment.video.requestKeyframe()
            return
        }
        sentSinceFeedback += datagrams.count
        if let lane {
            for datagram in datagrams {
                guard await lane.send(BrowserStreamPayload.encodedDatagram(datagram)) else { break }
            }
            return
        }
        let started = clock.now
        for datagram in datagrams {
            // No record keyframe flag: one shard does not restore state by itself.
            guard (try? await channel.send(binary: BrowserStreamPayload.encodedDatagram(datagram))) != nil else { return }
        }
        let interval = Duration.seconds(1) / Int(max(1, min(screen.refreshHz, 60)))
        if clock.now - started > interval * 2 { bitrate.sendStalled() }
    }

    private func pumpEvents() async {
        for await event in await attachment.events() {
            guard !finished else { return }
            switch event {
            case .page(let page): await sendRb(.page(page))
            case .cursor(let cursor): await sendRb(.cursor(cursor))
            case .textInput(let type, let caret): await sendRb(.textInput(inputType: type, compositionRects: [], caret: caret))
            case .clipboardWrite(let items): await sendRb(.clipboardWrite(items: items))
            case .geometry(let geometry):
                self.geometry = geometry
                resize()
                await attachment.video.requestKeyframe()
            case .closed(let reason):
                await sendRb(.closed(reason: reason))
                await channel.close(code: "browser.tab_closed", message: reason)
                return
            }
        }
    }

    private func pumpLanes() async {
        for await lane in await channel.datagramLanes() {
            self.lane = lane
            while let data = await lane.receive() {
                guard let payload = try? BrowserStreamPayload(record: data) else { continue }
                await handle(payload)
            }
            if self.lane === lane { self.lane = nil }
        }
    }

    private func sendRb(_ message: RbControl) async {
        guard let data = try? BrowserStreamPayload.rb(message).encoded() else { return }
        try? await channel.send(binary: data)
    }

    // MARK: Viewer to host

    private func receiveLoop() async {
        while !finished {
            switch await channel.receive() {
            case .closed:
                return
            case .gap:
                continue
            case .json(let value):
                // The only JSON a phone sends after open is channel.close.
                if case .channelClose? = try? MobileFrame(value: value) {
                    await channel.close()
                    return
                }
            case .binary(let data, _):
                guard let payload = try? BrowserStreamPayload(record: data) else {
                    await channel.close(code: "proto.bad_record", message: "not an rd stream frame")
                    return
                }
                guard await handle(payload) else { return }
            }
        }
    }

    /// Returns false when the channel was closed.
    @discardableResult
    private func handle(_ payload: BrowserStreamPayload) async -> Bool {
        switch payload {
        case .datagram(let header, let body):
            switch header.kind {
            case .input: return await applyInput(body)
            case .feedback: await applyFeedback(body)
            default: break
            }
        case .control:
            guard let message = payload.rbControl else { return true }
            return await apply(message)
        }
        return true
    }

    private func applyInput(_ body: Data) async -> Bool {
        guard let packet = try? RdInputPacket(decoding: body) else {
            await channel.close(code: "proto.bad_record", message: "bad input packet")
            return false
        }
        for (offset, event) in packet.events.enumerated() {
            let seq = packet.firstSeq &+ UInt32(offset)
            if seq <= lastAppliedInput { continue }
            guard seq == lastAppliedInput + 1 else {
                await channel.close(code: "validation.invalid", message: "input seq \(seq) after \(lastAppliedInput)")
                return false
            }
            // A revoked device's input never reaches the page.
            guard await gate.isOpen else { return true }
            lastAppliedInput = seq
            guard let input = try? RbInputEvent(rdEvent: event) else { continue }
            await attachment.apply(input)
        }
        let ack = RdDatagramHeader(kind: .inputAck)
        if let data = try? BrowserStreamPayload.datagram(ack, RdInputAck(appliedSeq: lastAppliedInput).encoded).encoded() {
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
        bitrate.feedback(lossFraction: loss, needRecovery: feedback.needRecovery, now: clock.now)
        if feedback.needRecovery { await attachment.video.requestKeyframe() }
    }

    private func apply(_ message: RbControl) async -> Bool {
        switch message {
        case .navigate(let request, let text):
            await sendRb(.navigateResult(request: request, refused: await navigate(text)))
        case .history(let op):
            guard await gate.isOpen else { return true }
            await attachment.history(op)
        case .screen(let seq, let screen):
            guard screen.cssWidth >= 1, screen.cssHeight >= 1, screen.scale > 0 else { return true }
            self.screen = screen
            resize()
            await attachment.video.requestKeyframe()
            await sendRb(.screenApplied(seq: seq, pixelWidth: UInt32(size.pixelWidth), pixelHeight: UInt32(size.pixelHeight),
                                        scale: Double(size.pixelWidth) / max(geometry.cssWidth, 1)))
        case .visibility(let visible):
            await attachment.setVisible(visible)
        case .clipboardPush(_, let items):
            guard await gate.isOpen else { return true }
            await attachment.pasteboard(items)
        case .close:
            await channel.close()
            return false
        default:
            break
        }
        return true
    }

    private func navigate(_ text: String) async -> RbNavigateRefusal? {
        guard await gate.isOpen else { return .notAllowed }
        switch policy.check(text) {
        case .failure(let refusal):
            return refusal
        case .success(let url):
            do {
                try await attachment.load(url)
                return nil
            } catch {
                return .failed
            }
        }
    }

    private func resize() {
        let scale = min(max(screen.scale, 0.5), Self.maxScale)
        size = BrowserEncodeSize(page: geometry, viewerPixelWidth: Double(screen.cssWidth) * scale)
    }
}
