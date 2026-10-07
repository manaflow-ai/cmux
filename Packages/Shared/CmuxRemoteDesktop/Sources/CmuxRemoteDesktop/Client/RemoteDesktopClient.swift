public import CmuxBrowserStream
import CmuxLink
import CmuxMobileLink
import CmuxMobileWire
import Foundation

/// The phone side of one `rd` channel (c3-rd.md 2): opens the channel and
/// its datagram lane, reassembles video from both and tags every frame
/// with the view it was encoded for, sends rd input in sequence order,
/// view requests, mode, clipboard and VNC auth, and rd feedback (a recovery
/// request after a loss).
///
/// `frames` and `events` each have one consumer. Frames buffer the newest
/// 30; a consumer that falls behind sees a reference gap and calls
/// `requestRecovery()`.
public actor RemoteDesktopClient {
    public nonisolated let frames: AsyncStream<RemoteDesktopFrame>
    public nonisolated let events: AsyncStream<RemoteDesktopEvent>

    /// Most events in one input packet (far under rd's 255 and one lane datagram).
    static let maxEventsPerPacket = 32
    /// Frames held while their view's `view_applied` is still in flight.
    static let maxHeldFrames = 8

    private let opener: any RemoteDesktopChannelOpener
    private let params: RemoteDesktopChannelParams
    private let framesContinuation: AsyncStream<RemoteDesktopFrame>.Continuation
    private let eventsContinuation: AsyncStream<RemoteDesktopEvent>.Continuation
    private let origin = ContinuousClock.now

    private var channel: MobileChannel?
    private var lane: MobileDatagramLane?
    private var opened: RemoteDesktopChannelOpened?
    private var closed = false
    private var tasks: [Task<Void, Never>] = []

    private var views: [UInt16: DesktopView] = [:]
    private var frameStreams: [UInt32: UInt16] = [:]
    private var held: [(RdCompletedFrame, UInt16)] = []
    private var reassembler = RdReassembler()
    private var arrivals: [RdArrival] = []
    private var recoveryRequested = false
    private var laneCarriesVideo = false
    private var nextInputSeq: UInt32 = 1
    private var nextViewSeq: UInt32 = 1
    private var nextClipboardSeq: UInt32 = 1

    public init(opener: any RemoteDesktopChannelOpener, params: RemoteDesktopChannelParams) {
        self.opener = opener
        self.params = params
        (frames, framesContinuation) = AsyncStream.makeStream(of: RemoteDesktopFrame.self, bufferingPolicy: .bufferingNewest(30))
        (events, eventsContinuation) = AsyncStream.makeStream(of: RemoteDesktopEvent.self)
    }

    /// The A0 id of the rd channel (0 before `open()`).
    public var id: UInt32 { channel?.id ?? 0 }

    // MARK: Open and close

    /// Opens the channel, then the datagram lane when the path has one.
    /// Throws `refused` with the Mac's code.
    @discardableResult
    public func open() async throws -> RemoteDesktopChannelOpened {
        guard channel == nil, !closed else { throw RemoteDesktopClientError.notOpen }
        let request = MobileChannelRequest(kind: .rd, channelClass: .interactive, window: 1 << 20, params: params.params,
                                           stream: "rd/\(params.target.kind.rawValue)", priority: .input)
        let accepted: MobileOpenedChannel
        do {
            accepted = try await opener.openChannel(request)
        } catch MobileLinkClientError.refused(let code, let message, _) {
            throw RemoteDesktopClientError.refused(code: code, message: message)
        } catch MobileLinkClientError.protocolViolation(let reason) {
            throw RemoteDesktopClientError.protocolViolation(reason)
        } catch {
            throw RemoteDesktopClientError.linkLost
        }
        let opened: RemoteDesktopChannelOpened
        do {
            opened = try RemoteDesktopChannelOpened(params: accepted.opened.params)
        } catch {
            await accepted.channel.abort()
            throw RemoteDesktopClientError.protocolViolation("channel.opened: \(error.message)")
        }
        channel = accepted.channel
        self.opened = opened
        views[opened.view.stream] = opened.view
        startReceiving(accepted.channel)
        if params.datagramLane, let lane = try? await opener.openDatagramLane(pairedWith: accepted) {
            self.lane = lane
            startReceiving(lane: lane)
            // The Mac binds the lane when its first record arrives.
            await sendLane(.datagram(RdDatagramHeader(kind: .feedback), RdFeedback().encoded))
        }
        return opened
    }

    /// Closes the stream.
    public func close() async {
        guard !closed else { return }
        if let channel {
            try? await channel.send(frame: .channelClose(ChannelCloseFrame(channel: channel.id)))
        }
        await teardown(reason: "local")
    }

    // MARK: Requests

    /// Sends input events; they reach the target once and in call order.
    public func send(_ input: [RdInputEvent]) async throws {
        var rest = input[...]
        while !rest.isEmpty {
            let chunk = rest.prefix(Self.maxEventsPerPacket)
            rest = rest.dropFirst(chunk.count)
            let packet = RdInputPacket(firstSeq: nextInputSeq, events: Array(chunk))
            nextInputSeq &+= UInt32(chunk.count)
            try await send(.datagram(RdDatagramHeader(kind: .input), try packet.encoded()))
        }
    }

    /// Asks the Mac to show `rect` (target pixels) at up to `pixelWidth x
    /// pixelHeight`. Returns the request's seq; `viewApplied` answers it.
    @discardableResult
    public func requestView(_ rect: DesktopRect, pixelWidth: Int, pixelHeight: Int) async throws -> UInt32 {
        let seq = nextViewSeq
        nextViewSeq &+= 1
        try await send(.control(.view(DesktopView(seq: seq, rect: rect, pixelWidth: pixelWidth, pixelHeight: pixelHeight))))
        return seq
    }

    public func selectDisplay(_ id: UInt32) async throws {
        try await send(.control(.select(display: id)))
    }

    public func listWindows() async throws {
        try await send(.control(.windowsList))
    }

    public func setMode(_ mode: DesktopMode) async throws {
        try await send(.control(.mode(mode)))
    }

    /// Pushes the phone's clipboard right before a paste the user started.
    public func pushClipboard(_ text: String) async throws {
        let seq = nextClipboardSeq
        nextClipboardSeq &+= 1
        try await send(.control(.clipboardPush(seq: seq, text: text)))
    }

    /// "Copy from Mac": the answer arrives as `clipboard`.
    public func pullClipboard() async throws {
        let seq = nextClipboardSeq
        nextClipboardSeq &+= 1
        try await send(.control(.clipboardPull(seq: seq)))
    }

    /// Answers `state(.authRequired)` with the VNC password.
    public func authenticate(password: String) async throws {
        try await send(.control(.auth(password: password)))
    }

    /// The decoder could not use a frame: ask for a keyframe (once per loss).
    public func requestRecovery() async {
        guard !recoveryRequested else { return }
        recoveryRequested = true
        await sendFeedback(needRecovery: true)
    }

    // MARK: Receive

    private func startReceiving(_ channel: MobileChannel) {
        tasks.append(Task { [weak self] in
            while true {
                let inbound = await channel.receive()
                guard let self, await self.handle(inbound) else { return }
            }
        })
    }

    private func startReceiving(lane: MobileDatagramLane) {
        tasks.append(Task { [weak self] in
            while let data = await lane.receive() {
                guard let self else { return }
                await self.handleLane(data)
            }
            await self?.laneEnded()
        })
    }

    /// Returns false when the channel is done.
    private func handle(_ inbound: MobileInbound) async -> Bool {
        switch inbound {
        case .closed:
            await teardown(reason: "remote")
            return false
        case .gap:
            reassembler.reset()
            frameStreams.removeAll()
            held.removeAll()
            recoveryRequested = false
            await requestRecovery()
            return true
        case .json(let value):
            if case .channelClosed(let frame)? = try? MobileFrame(value: value) {
                await teardown(reason: frame.code ?? "closed")
                return false
            }
            return true
        case .binary(let data, _):
            guard let payload = try? DesktopPayload(record: data) else { return true }
            await apply(payload)
            return true
        }
    }

    private func handleLane(_ data: Data) async {
        guard let payload = try? DesktopPayload(record: data) else { return }
        if !laneCarriesVideo, case .datagram(let header, _) = payload, header.kind == .video {
            laneCarriesVideo = true
            eventsContinuation.yield(.datagramLane(active: true))
        }
        await apply(payload)
    }

    private func laneEnded() {
        lane = nil
        if laneCarriesVideo { eventsContinuation.yield(.datagramLane(active: false)) }
        laneCarriesVideo = false
    }

    private func apply(_ payload: DesktopPayload) async {
        switch payload {
        case .control(let message):
            apply(message)
        case .otherControl:
            break
        case .datagram(let header, let body):
            switch header.kind {
            case .video:
                await receiveVideo(header, body)
            case .inputAck:
                if let ack = try? RdInputAck(decoding: body) { eventsContinuation.yield(.inputApplied(ack.appliedSeq)) }
            default:
                break
            }
        }
    }

    private func apply(_ message: DesktopMessage) {
        switch message {
        case .viewApplied(let view):
            views[view.stream] = view
            eventsContinuation.yield(.viewApplied(view))
            releaseHeld()
        case .target(let info): eventsContinuation.yield(.target(info))
        case .windows(let windows): eventsContinuation.yield(.windows(windows))
        case .modeApplied(let mode, let reason): eventsContinuation.yield(.modeApplied(mode: mode, reason: reason))
        case .clipboard(_, let text): eventsContinuation.yield(.clipboard(text))
        case .state(let state, let reason): eventsContinuation.yield(.state(state, reason: reason))
        case .ended(let reason): eventsContinuation.yield(.ended(reason: reason))
        case .view, .select, .windowsList, .mode, .clipboardPush, .clipboardPull, .auth:
            break
        }
    }

    private func receiveVideo(_ header: RdDatagramHeader, _ body: Data) async {
        let micros = UInt32(truncatingIfNeeded: (ContinuousClock.now - origin).rdMicros)
        if arrivals.count < RdFeedback.maxArrivals {
            arrivals.append(RdArrival(transportSeq: header.transportSeq, arrivalMicros: micros))
        }
        if frameStreams[header.frame] == nil { frameStreams[header.frame] = header.stream }
        let released = reassembler.push(header, payload: body)
        for frame in released {
            if frame.isKeyframe || frame.flags.contains(.recovery) { recoveryRequested = false }
            let stream = frameStreams.removeValue(forKey: frame.frame) ?? header.stream
            deliver(frame, stream: stream)
        }
        if let last = released.last?.frame {
            frameStreams = frameStreams.filter { $0.key > last }
        }
        if reassembler.needsRecovery, !recoveryRequested {
            recoveryRequested = true
            await sendFeedback(needRecovery: true)
        } else if !released.isEmpty {
            await sendFeedback(needRecovery: false)
        }
    }

    /// Frames go out in order; one whose view is not known yet waits (with
    /// everything after it) for that view's `view_applied`.
    private func deliver(_ frame: RdCompletedFrame, stream: UInt16) {
        guard held.isEmpty, let view = views[stream] else {
            held.append((frame, stream))
            if held.count > Self.maxHeldFrames {
                // The answer is lost or late: show with the newest known view
                // rather than freeze.
                flushHeld(fallback: true)
            }
            return
        }
        emit(frame, view: view)
    }

    private func releaseHeld() {
        flushHeld(fallback: false)
    }

    private func flushHeld(fallback: Bool) {
        while let (frame, stream) = held.first {
            guard let view = views[stream] ?? (fallback ? latestView : nil) else { return }
            held.removeFirst()
            emit(frame, view: view)
        }
    }

    private var latestView: DesktopView? {
        views.values.max { $0.seq < $1.seq }
    }

    private func emit(_ frame: RdCompletedFrame, view: DesktopView) {
        framesContinuation.yield(RemoteDesktopFrame(frame: frame.frame, refFrame: frame.body.refFrame,
                                                    isKeyframe: frame.isKeyframe, captureMicros: frame.body.captureMicros,
                                                    accessUnit: frame.body.accessUnit, view: view))
    }

    private func sendFeedback(needRecovery: Bool) async {
        _ = reassembler.takeLosses()
        let feedback = RdFeedback(ackedFrame: reassembler.lastReleased, needRecovery: needRecovery, arrivals: arrivals)
        arrivals.removeAll()
        let payload = DesktopPayload.datagram(RdDatagramHeader(kind: .feedback), feedback.encoded)
        // A recovery request must not be lost: it rides the reliable channel.
        if lane != nil, !needRecovery {
            await sendLane(payload)
        } else {
            try? await send(payload)
        }
    }

    // MARK: Send

    private func send(_ payload: DesktopPayload) async throws {
        guard let channel, !closed else { throw RemoteDesktopClientError.notOpen }
        do {
            try await channel.send(binary: try payload.encoded())
        } catch let error as RdWireError {
            throw error
        } catch {
            throw RemoteDesktopClientError.linkLost
        }
    }

    /// Datagram-lane sends never wait (unreliable lanes drop their oldest).
    private func sendLane(_ payload: DesktopPayload) async {
        guard let lane, let data = try? payload.encoded() else { return }
        await lane.send(data)
    }

    // MARK: Teardown

    private func teardown(reason: String) async {
        guard !closed else { return }
        closed = true
        eventsContinuation.yield(.closed(reason: reason))
        eventsContinuation.finish()
        framesContinuation.finish()
        let channel = channel
        let lane = lane
        self.lane = nil
        for task in tasks { task.cancel() }
        tasks.removeAll()
        await lane?.close()
        await channel?.finish()
    }
}

extension Duration {
    var rdMicros: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }
}
