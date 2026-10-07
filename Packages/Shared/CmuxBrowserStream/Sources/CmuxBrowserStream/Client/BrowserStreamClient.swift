import CmuxLink
import CmuxMobileWire
public import Foundation

/// The phone side of one `browser` channel (c2-browser-stream.md section 2):
/// opens the channel and its datagram lane, reassembles video from both,
/// sends rb input in sequence order, navigation and history requests, and
/// rd feedback (a recovery request after a loss).
///
/// `frames` and `events` each have one consumer. Frames buffer the newest
/// 30; a consumer that falls behind sees a reference gap and calls
/// `requestRecovery()`, which asks the Mac for a keyframe.
public actor BrowserStreamClient {
    public nonisolated let frames: AsyncStream<BrowserVideoFrame>
    public nonisolated let events: AsyncStream<BrowserStreamEvent>

    private let session: any MobileSessionLink
    private var params: BrowserChannelParams
    private let framesContinuation: AsyncStream<BrowserVideoFrame>.Continuation
    private let eventsContinuation: AsyncStream<BrowserStreamEvent>.Continuation
    private let origin = ContinuousClock.now

    private var channelID: UInt32 = 0
    private var channel: LinkChannel?
    private var lane: LinkChannel?
    private var opened: BrowserChannelOpened?
    private var codec: BrowserVideoCodec = .h264
    private var closed = false

    private var sendSeq: UInt64 = 0
    private var laneSendSeq: UInt64 = 0
    private var receiveSeq: UInt64 = 0
    private var sending = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []

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

    public init(session: any MobileSessionLink, params: BrowserChannelParams) {
        self.session = session
        self.params = params
        (frames, framesContinuation) = AsyncStream.makeStream(of: BrowserVideoFrame.self, bufferingPolicy: .bufferingNewest(30))
        (events, eventsContinuation) = AsyncStream.makeStream(of: BrowserStreamEvent.self)
    }

    /// The A0 id of the browser channel (0 before `open()`).
    public var id: UInt32 { channelID }

    // MARK: Open and close

    /// Opens the channel (and the datagram lane when the path has an
    /// unreliable lane). Throws `refused` with the host's code.
    @discardableResult
    public func open() async throws -> BrowserChannelOpened {
        guard channel == nil, !closed else { throw BrowserStreamClientError.notOpen }
        let link = session.link
        channelID = await session.allocateChannelID()
        if params.datagramLane {
            do {
                lane = try await link.openChannel(ChannelDescriptor(
                    stream: DatagramLaneName(channel: channelID).stream, reliability: .unreliableUnordered, priority: .media))
            } catch {
                params.datagramLane = false
            }
        }
        let channel = try await link.openChannel(ChannelDescriptor(stream: "browser/\(params.tab)", reliability: .reliableOrdered,
                                                                   priority: .input))
        self.channel = channel
        let open = ChannelOpenFrame(channel: channelID, kind: .browser, channelClass: .interactive, window: 1 << 20,
                                    params: params.params)
        try await sendRecord(json: try MobileFrame.channelOpen(open).jsonValue)
        let first = await Self.nextEvent(channel)
        guard case .message(let message)? = first, let record = try? StreamRecord(decoding: message.payload),
              record.channel == channelID, record.seq == 1, record.flags.contains(.json),
              let frame = try? MobileFrame(value: try record.jsonObject()) else {
            await teardown(reason: "protocol")
            throw BrowserStreamClientError.protocolViolation("the first host record must be channel.opened or channel.refused")
        }
        receiveSeq = 1
        switch frame {
        case .channelOpened(let ok):
            let opened = try BrowserChannelOpened(params: ok.params)
            self.opened = opened
            codec = opened.encoder
            startReceiving(channel)
            if let lane {
                startReceiving(lane: lane)
                // The host learns the lane from this first record; until it
                // arrives video rides the browser channel.
                await sendLane(.datagram(RdDatagramHeader(kind: .feedback), RdFeedback().encoded))
            }
            return opened
        case .channelRefused(let refused):
            await teardown(reason: refused.code)
            throw BrowserStreamClientError.refused(code: refused.code, message: refused.message)
        default:
            await teardown(reason: "protocol")
            throw BrowserStreamClientError.protocolViolation("unexpected \(frame.type.rawValue)")
        }
    }

    /// Closes the stream. Pending navigations fail with `notOpen`.
    public func close() async {
        guard !closed else { return }
        if channel != nil {
            try? await sendRecord(json: try MobileFrame.channelClose(ChannelCloseFrame(channel: channelID)).jsonValue)
        }
        await teardown(reason: "local")
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

    private func startReceiving(_ channel: LinkChannel) {
        tasks.append(Task { [weak self] in
            var iterator = channel.events.makeAsyncIterator()
            while let event = await iterator.next() {
                guard let self, await self.handle(event) else { return }
            }
            await self?.teardown(reason: "remote")
        })
    }

    private func startReceiving(lane: LinkChannel) {
        tasks.append(Task { [weak self] in
            var iterator = lane.events.makeAsyncIterator()
            while let event = await iterator.next() {
                guard let self else { return }
                if case .message(let message) = event {
                    await self.handleLane(message.payload)
                } else if case .closed = event {
                    await self.laneEnded()
                    return
                }
            }
        })
    }

    /// Returns false when the channel is done.
    private func handle(_ event: ChannelEvent) async -> Bool {
        switch event {
        case .closed:
            await teardown(reason: "remote")
            return false
        case .gap:
            reassembler.reset()
            recoveryRequested = false
            await requestRecovery()
            return true
        case .message(let message):
            guard let record = try? StreamRecord(decoding: message.payload), record.channel == channelID,
                  record.seq == receiveSeq + 1 else {
                await teardown(reason: "proto.bad_record")
                return false
            }
            receiveSeq = record.seq
            if record.flags.contains(.json) {
                if case .channelClosed(let frame)? = try? MobileFrame(value: try record.jsonObject()) {
                    await teardown(reason: frame.code ?? "closed")
                    return false
                }
                return true
            }
            guard let payload = try? BrowserStreamPayload(record: record.payload) else { return true }
            await apply(payload)
            return true
        }
    }

    private func handleLane(_ data: Data) async {

        guard let record = try? StreamRecord(decoding: data), record.channel == channelID, !record.flags.contains(.json),
              let payload = try? BrowserStreamPayload(record: record.payload) else { return }
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
            await teardown(reason: reason)
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

    private func send(_ payload: BrowserStreamPayload) async throws {
        guard channel != nil, !closed else { throw BrowserStreamClientError.notOpen }
        try await sendRecord(binary: try payload.encoded())
    }

    /// Datagram-lane sends never wait (unreliable lanes drop their oldest).
    private func sendLane(_ payload: BrowserStreamPayload) async {
        guard let lane, let data = try? payload.encoded() else { return }
        laneSendSeq += 1
        let record = StreamRecord(channel: channelID, seq: laneSendSeq, payload: data)
        _ = try? await lane.send(record.encoded)
    }

    private func sendRecord(json: JSONValue) async throws {
        try await sendRecord(try json.canonicalData(), flags: .json)
    }

    private func sendRecord(binary: Data) async throws {
        try await sendRecord(binary, flags: [])
    }

    /// One record at a time, in call order, so seqs stay contiguous while a
    /// send waits for link credit.
    private func sendRecord(_ payload: Data, flags: RecordFlags) async throws {
        guard let channel else { throw BrowserStreamClientError.notOpen }
        await acquireSend()
        defer { releaseSend() }
        let record = StreamRecord(channel: channelID, seq: sendSeq + 1, flags: flags, payload: payload)
        try await channel.send(record.encoded)
        sendSeq += 1
    }

    private func acquireSend() async {
        guard sending else {
            sending = true
            return
        }
        await withCheckedContinuation { sendWaiters.append($0) }
    }

    private func releaseSend() {
        if sendWaiters.isEmpty {
            sending = false
        } else {
            sendWaiters.removeFirst().resume()
        }
    }

    // MARK: Teardown

    private func teardown(reason: String) async {
        guard !closed else { return }
        closed = true
        for continuation in navigations.values { continuation.resume(throwing: BrowserStreamClientError.notOpen) }
        navigations.removeAll()
        eventsContinuation.yield(.closed(reason: reason))
        eventsContinuation.finish()
        framesContinuation.finish()
        let channel = channel
        let lane = lane
        self.lane = nil
        for task in tasks { task.cancel() }
        tasks.removeAll()
        await lane?.close()
        await channel?.close()
    }

    private nonisolated static func nextEvent(_ channel: LinkChannel) async -> ChannelEvent? {
        var iterator = channel.events.makeAsyncIterator()
        return await iterator.next()
    }
}

extension Duration {
    var microseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }
}
