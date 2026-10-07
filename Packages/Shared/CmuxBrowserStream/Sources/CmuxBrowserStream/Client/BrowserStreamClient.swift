import CmuxLink
public import CmuxMobileLink
import CmuxMobileWire
public import Foundation

/// The phone side of one `browser` or `simulator` channel (c2-browser-stream.md section 2, c14-web.md 6),
/// opened on the phone's one `MobileLinkClient` per Mac (the same session
/// terminals and files use): opens the channel and its datagram lane,
/// reassembles video from both, sends rb input in sequence order,
/// navigation and history requests, and rd feedback (a recovery request
/// after a loss).
///
/// `frames` and `events` each have one consumer. Frames buffer the newest
/// 30; a consumer that falls behind sees a reference gap and calls
/// `requestRecovery()`, which asks the Mac for a keyframe.
public actor BrowserStreamClient {
    public nonisolated let frames: AsyncStream<BrowserVideoFrame>
    public nonisolated let events: AsyncStream<BrowserStreamEvent>

    private let client: MobileLinkClient
    private var params: BrowserChannelParams
    private let framesContinuation: AsyncStream<BrowserVideoFrame>.Continuation
    private let eventsContinuation: AsyncStream<BrowserStreamEvent>.Continuation
    private let origin = ContinuousClock.now

    private var channel: MobileChannel?
    private var lane: MobileDatagramLane?
    private var codec: BrowserVideoCodec = .h264
    private var closed = false

    private var reassembler = RdReassembler()
    private var arrivals: [RdArrival] = []
    private var recoveryRequested = false
    private var laneCarriesVideo = false
    private var nextInputSeq: UInt32 = 1
    private var nextRequest: UInt64 = 1
    private var nextScreenSeq: UInt32 = 1
    private var nextClipboardSeq: UInt32 = 1
    private var navigations: [UInt64: CheckedContinuation<RbNavigateRefusal?, any Error>] = [:]
    private var tasks: [Task<Void, Never>] = []

    public init(client: MobileLinkClient, params: BrowserChannelParams) {
        self.client = client
        self.params = params
        (frames, framesContinuation) = AsyncStream.makeStream(of: BrowserVideoFrame.self, bufferingPolicy: .bufferingNewest(30))
        (events, eventsContinuation) = AsyncStream.makeStream(of: BrowserStreamEvent.self)
    }

    /// The A0 id of the browser channel (0 before `open()`).
    public var id: UInt32 { channel?.id ?? 0 }

    // MARK: Open and close

    /// Opens the channel, then the datagram lane when the path has an
    /// unreliable lane. Throws `refused` with the host's code.
    @discardableResult
    public func open() async throws -> BrowserChannelOpened {
        guard channel == nil, !closed else { throw BrowserStreamClientError.notOpen }
        let request = MobileChannelRequest(kind: params.target.kind, channelClass: .interactive, window: 1 << 20,
                                           params: params.params, stream: params.target.stream, priority: .input)
        let accepted: MobileOpenedChannel
        do {
            accepted = try await client.open(request)
        } catch MobileLinkClientError.refused(let code, let message, _) {
            teardown(reason: code)
            throw BrowserStreamClientError.refused(code: code, message: message)
        } catch MobileLinkClientError.protocolViolation(let message) {
            teardown(reason: "protocol")
            throw BrowserStreamClientError.protocolViolation(message)
        } catch {
            teardown(reason: "link")
            throw BrowserStreamClientError.notOpen
        }
        let opened: BrowserChannelOpened
        do {
            opened = try BrowserChannelOpened(params: accepted.opened.params)
        } catch {
            await accepted.channel.abort()
            teardown(reason: "protocol")
            throw BrowserStreamClientError.protocolViolation("channel.opened params: \(error)")
        }
        channel = accepted.channel
        codec = opened.encoder
        startReceiving(accepted.channel)
        if params.datagramLane, let lane = try? await client.openDatagramLane(for: accepted) {
            self.lane = lane
            startReceiving(lane: lane)
            // Until the Mac binds the lane, video rides the browser channel.
            await sendLane(.datagram(RdDatagramHeader(kind: .feedback), RdFeedback().encoded))
        }
        return opened
    }

    /// Closes the stream. Pending navigations fail with `notOpen`.
    public func close() async {
        guard !closed else { return }
        if let channel {
            try? await channel.send(frame: .channelClose(ChannelCloseFrame(channel: channel.id)))
        }
        teardown(reason: "local")
    }

    // MARK: Requests

    /// Sends one input event; events reach the page once and in call order.
    public func send(_ input: RbInputEvent) async throws {
        let seq = nextInputSeq
        nextInputSeq &+= 1
        let packet = RdInputPacket(firstSeq: seq, events: [try input.rdEvent()])
        try await send(.datagram(RdDatagramHeader(kind: .input), try packet.encoded()))
    }

    /// Asks the page owner to load `url`. Returns nil when it started, or the
    /// host's refusal (`scheme` for anything but http and https).
    public func navigate(to url: URL) async throws -> RbNavigateRefusal? {
        guard channel != nil, !closed else { throw BrowserStreamClientError.notOpen }
        let request = nextRequest
        nextRequest += 1
        return try await withCheckedThrowingContinuation { continuation in
            navigations[request] = continuation
            Task { await self.sendNavigate(request, url: url) }
        }
    }

    public func history(_ op: RbHistoryOp) async throws {
        try await send(.rb(.history(op)))
    }

    /// Reports a new viewport (rotation, or a pinch that changed the zoom bucket).
    public func setScreen(_ screen: RbScreenInfo) async throws {
        let seq = nextScreenSeq
        nextScreenSeq += 1
        params.screen = screen
        try await send(.rb(.screen(seq: seq, screen: screen)))
    }

    public func setVisible(_ visible: Bool) async throws {
        try await send(.rb(.visibility(visible: visible)))
    }

    /// Pushes the phone's clipboard right before a paste the user started.
    public func pushClipboard(_ text: String) async throws {
        let seq = nextClipboardSeq
        nextClipboardSeq += 1
        try await send(.rb(.clipboardPush(seq: seq, items: [.text(text)])))
    }

    /// Answers a menu or dialog the phone does not show yet.
    public func cancelMenu(token: UInt64) async throws {
        try await send(.rb(.menuResult(token: token, choice: .cancel)))
    }

    public func dismissDialog(token: UInt64) async throws {
        try await send(.rb(.dialogResult(token: token, accept: false, text: nil)))
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
            teardown(reason: "remote")
            return false
        case .gap:
            reassembler.reset()
            recoveryRequested = false
            await requestRecovery()
            return true
        case .json(let value):
            if case .channelClosed(let frame)? = try? MobileFrame(value: value) {
                teardown(reason: frame.code ?? "closed")
                return false
            }
            return true
        case .binary(let data, _):
            guard let payload = try? BrowserStreamPayload(record: data) else { return true }
            await apply(payload)
            return true
        }
    }

    private func handleLane(_ data: Data) async {
        guard let payload = try? BrowserStreamPayload(record: data) else { return }
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

    private func apply(_ payload: BrowserStreamPayload) async {
        switch payload {
        case .control:
            guard let message = payload.rbControl else { return }
            await apply(message)
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

    private func apply(_ message: RbControl) async {
        switch message {
        case .page(let page): eventsContinuation.yield(.page(page))
        case .state(let state): eventsContinuation.yield(.state(state))
        case .cursor(let cursor): eventsContinuation.yield(.cursor(cursor))
        case .textInput(let type, _, let caret): eventsContinuation.yield(.textInput(inputType: type, caret: caret))
        case .clipboardWrite(let items): eventsContinuation.yield(.clipboardWrite(items))
        case .screenApplied(_, let width, let height, _):
            eventsContinuation.yield(.screenApplied(pixelWidth: width, pixelHeight: height))
        case .navigateResult(let request, let refused):
            navigations.removeValue(forKey: request)?.resume(returning: refused)
        case .menuShow(let token, _):
            try? await cancelMenu(token: token)
        case .dialogShow(let token, _):
            try? await dismissDialog(token: token)
        case .openTab(let request, _, _, _):
            try? await send(.rb(.openTabResult(request: request, tab: nil, refused: "not_supported")))
        case .closed(let reason):
            teardown(reason: reason)
        default:
            break
        }
    }

    private func receiveVideo(_ header: RdDatagramHeader, _ body: Data) async {
        let micros = UInt32(truncatingIfNeeded: (ContinuousClock.now - origin).microseconds)
        if arrivals.count < RdFeedback.maxArrivals {
            arrivals.append(RdArrival(transportSeq: header.transportSeq, arrivalMicros: micros))
        }
        let released = reassembler.push(header, payload: body)
        for frame in released {
            if frame.isKeyframe || frame.flags.contains(.recovery) { recoveryRequested = false }
            framesContinuation.yield(BrowserVideoFrame(frame: frame.frame, refFrame: frame.body.refFrame,
                                                       isKeyframe: frame.isKeyframe, codec: codec,
                                                       captureMicros: frame.body.captureMicros,
                                                       accessUnit: frame.body.accessUnit))
        }
        if reassembler.needsRecovery, !recoveryRequested {
            recoveryRequested = true
            await sendFeedback(needRecovery: true)
        } else if !released.isEmpty {
            await sendFeedback(needRecovery: false)
        }
    }

    private func sendFeedback(needRecovery: Bool) async {
        _ = reassembler.takeLosses()
        let feedback = RdFeedback(ackedFrame: reassembler.lastReleased, needRecovery: needRecovery, arrivals: arrivals)
        arrivals.removeAll()
        let payload = BrowserStreamPayload.datagram(RdDatagramHeader(kind: .feedback), feedback.encoded)
        // A recovery request must not be lost: it rides the reliable channel.
        if lane != nil, !needRecovery {
            await sendLane(payload)
        } else {
            try? await send(payload)
        }
    }

    // MARK: Send

    private func sendNavigate(_ request: UInt64, url: URL) async {
        do {
            try await send(.rb(.navigate(request: request, url: url.absoluteString)))
        } catch {
            navigations.removeValue(forKey: request)?.resume(throwing: error)
        }
    }

    /// One record at a time, in call order (`MobileChannel` keeps seqs contiguous).
    private func send(_ payload: BrowserStreamPayload) async throws {
        guard let channel, !closed else { throw BrowserStreamClientError.notOpen }
        try await channel.send(binary: try payload.encoded())
    }

    /// Datagram-lane sends never wait (unreliable lanes drop their oldest).
    private func sendLane(_ payload: BrowserStreamPayload) async {
        guard let lane, let data = try? payload.encoded() else { return }
        await lane.send(data)
    }

    // MARK: Teardown

    private func teardown(reason: String) {
        guard !closed else { return }
        closed = true
        for continuation in navigations.values { continuation.resume(throwing: BrowserStreamClientError.notOpen) }
        navigations.removeAll()
        eventsContinuation.yield(.closed(reason: reason))
        eventsContinuation.finish()
        framesContinuation.finish()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        let channel = channel
        let lane = lane
        self.lane = nil
        Task {
            await lane?.close()
            await channel?.abort()
        }
    }
}

extension Duration {
    var microseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }
}
