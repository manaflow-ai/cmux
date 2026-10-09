import CmuxLink
import CmuxMobileLink
import CmuxMobileWire
import CmuxTerminalRenderCore
import CmuxTerminalStream
import Foundation

/// The state behind one `LinkTerminalByteSource` (c1-terminal-rpc.md): the
/// attached channel, the delivery queue, prediction and telemetry. Every
/// attach gets an id; work of an older attach is ignored.
actor LinkTerminalConnection {
    let terminal: String
    private let client: MobileLinkClient
    private let options: TerminalLinkOptions
    private let clock: LinkClock
    private let describe: @Sendable (TerminalLinkFailure) -> String

    private var queue: TerminalDeliveryQueue?
    private var channel: MobileChannel?
    /// The client session generation `channel` belongs to.
    private var channelGeneration: UInt64?
    private var attachID: UInt64 = 0
    private var attachTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var badgeTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var readyTask: Task<Void, Never>?
    private var viewport: CmuxTerminalRenderCore.TerminalViewport
    private var sentGrid: (cols: Int, rows: Int)?
    private var sentVisible: Bool?
    private var awaitingKeyframe = false
    private var reattachesWithoutReady = 0
    private var requestCounter = 0
    private var predictor: TerminalEchoPredictor
    private var monitor = TerminalLatencyMonitor()
    private var telemetrySubscribers: [UUID: AsyncStream<TerminalLatencyReport>.Continuation] = [:]
    private var inputBusy = false
    private var history = TerminalHistoryTracker()
    private var inputWaiters: [CheckedContinuation<Void, Never>] = []

    init(terminal: String, client: MobileLinkClient, options: TerminalLinkOptions, clock: LinkClock,
         describe: @escaping @Sendable (TerminalLinkFailure) -> String) {
        self.terminal = terminal
        self.describe = describe
        self.client = client
        self.options = options
        self.clock = clock
        predictor = TerminalEchoPredictor(options: options.prediction)
        viewport = CmuxTerminalRenderCore.TerminalViewport(cols: 80, rows: 24, visible: false)
    }

    // MARK: Lifecycle

    func open(_ viewport: CmuxTerminalRenderCore.TerminalViewport) -> AsyncStream<TerminalSourceEvent> {
        stopAttach()
        queue?.finishDetached()
        let queue = TerminalDeliveryQueue()
        self.queue = queue
        self.viewport = viewport
        followBadges()
        startAttach()
        return AsyncStream(unfolding: { [weak self] in
            guard let item = await queue.next() else { return nil }
            if item.isFrame { await self?.delivered(item) }
            return item.event
        }, onCancel: {
            Task { await queue.cancel() }
        })
    }

    func close() async {
        stopAttach()
        badgeTask?.cancel()
        badgeTask = nil
        await queue?.finish()
        queue = nil
        for continuation in telemetrySubscribers.values { continuation.finish() }
        telemetrySubscribers.removeAll()
        history.finish()
    }

    private func stopAttach() {
        attachID &+= 1
        attachTask?.cancel()
        attachTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        cancelExpiry()
        readyTask?.cancel()
        readyTask = nil
        if let channel {
            Task { await channel.abort() }
        }
        channel = nil
        channelGeneration = nil
        sentGrid = nil
        sentVisible = nil
        awaitingKeyframe = false
        predictor.suspend()
    }

    private func startAttach() {
        let id = attachID
        attachTask = Task { [weak self] in await self?.attach(id) }
    }

    private func attach(_ id: UInt64) async {
        let wireViewport = CmuxMobileWire.TerminalViewport(cols: viewport.cols, rows: viewport.rows)
        let params = TerminalChannelParams(terminal: terminal, viewport: wireViewport, visible: viewport.visible,
                                           counts: viewport.visible,
                                           snapshot: TerminalSnapshotSupport(versions: options.snapshotVersions))
        let request = MobileChannelRequest(
            kind: .terminal, channelClass: .interactive, window: UInt32(options.window),
            params: (try? JSONValue(encoding: params))?.objectValue ?? [:],
            stream: "terminal/\(terminal)", priority: .input, budgetBytes: options.inputBudget)
        let opened: MobileOpenedChannel
        do {
            opened = try await client.open(request)
        } catch {
            guard id == attachID else { return }
            await end(Self.failure(for: error))
            return
        }
        guard id == attachID else {
            await opened.channel.abort()
            return
        }
        channel = opened.channel
        channelGeneration = opened.generation
        // A hidden attach did not count its size: the first visible change reports it.
        sentGrid = viewport.visible ? (viewport.cols, viewport.rows) : nil
        sentVisible = viewport.visible
        if let params = try? JSONValue.object(opened.opened.params).decode(as: TerminalOpenedParams.self) {
            await push(.grid(cols: params.cols, rows: params.rows, generation: params.generation))
            if let title = params.title, !title.isEmpty { await push(.title(title)) }
        }
        // The answer may have overtaken a viewport change made while opening.
        await viewportChanged(viewport)
        let channel = opened.channel
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                let inbound = await channel.receive()
                guard let self, await self.handle(inbound, attach: id) else { return }
            }
        }
    }

    /// A link gap, or the link session gone without the owner's word: attach
    /// again; the new channel starts with a READY.
    private func reattach() async {
        // The channel's session may be the casualty (a new link epoch leaves
        // its re-declared channels unserved): end it so the reopen dials fresh.
        if let generation = channelGeneration { await client.sessionEnded(generation) }
        reattachesWithoutReady += 1
        monitor.reattached()
        publishTelemetry()
        guard reattachesWithoutReady <= options.maxReattaches else {
            await end(.unstable)
            return
        }
        stopAttach()
        startAttach()
    }

    private func end(_ failure: TerminalLinkFailure) async {
        let queue = self.queue
        stopAttach()
        lastFailure = failure
        await queue?.push(.closed(reason: describe(failure)), at: clock.now)
        await queue?.finish()
    }

    /// The last reason the stream ended.
    private(set) var lastFailure: TerminalLinkFailure?

    // MARK: Host to phone

    private func handle(_ inbound: MobileInbound, attach id: UInt64) async -> Bool {
        guard id == attachID else { return false }
        switch inbound {
        case .binary(let payload, _):
            guard let frame = (try? TerminalFrame.decodeSkippingUnknown(payload)) ?? nil else { return true }
            await handle(frame)
            return true
        case .json(let value):
            return await handle(json: value)
        case .gap:
            await reattach()
            return false
        case .closed:
            await reattach()
            return false
        }
    }

    private func handle(_ frame: TerminalFrame) async {
        let now = clock.now
        if frame.kind == .snapshotReady {
            await queue?.dropFrames()
            awaitingKeyframe = false
            reattachesWithoutReady = 0
            readyTask?.cancel()
            readyTask = nil
            cancelExpiry()
            predictor.restored(generation: frame.generation, offset: frame.offset)
            monitor.keyframe()
            await push(.frame(frame))
            publishTelemetry()
            return
        }
        guard !awaitingKeyframe else { return }
        if frame.kind == .snapshotHistory { history.received(offset: frame.offset) }
        if frame.kind == .bytes {
            monitor.output(endingAt: frame.offset, at: now)
            switch predictor.reconcile(generation: frame.generation, offset: frame.offset, payload: frame.payload) {
            case .rollback:
                monitor.predictionRolledBack()
                await resync()
                publishTelemetry()
                return
            case .confirmed:
                monitor.predictionConfirmed()
                armExpiry()
            case .none:
                break
            }
            publishTelemetry()
        }
        await push(.frame(frame))
        if let queue, await queue.frameBytes > options.queueBudget {
            monitor.phoneOverflow()
            await resync()
            publishTelemetry()
        }
    }

    /// Drop what is queued and wait for a READY the source asks for.
    private func resync() async {
        awaitingKeyframe = true
        predictor.suspend()
        cancelExpiry()
        await queue?.dropFrames()
        requestCounter += 1
        await sendMessage(ChannelMessage(name: "terminal.snapshot_request", body: [
            "terminal": .string(terminal), "reason": .string("gap"), "have": .null,
            "request_id": .string("c1-resync-\(requestCounter)"),
        ]))
        armReadyDeadline()
    }

    private func handle(json value: JSONValue) async -> Bool {
        switch value["t"]?.stringValue {
        case "terminal.size":
            if case .int(let generation)? = value["generation"], case .int(let cols)? = value["cols"],
               case .int(let rows)? = value["rows"] {
                await push(.grid(cols: Int(cols), rows: Int(rows), generation: UInt32(truncatingIfNeeded: generation)))
            }
        case "terminal.title":
            if let title = value["title"]?.stringValue { await push(.title(title)) }
        case "terminal.kicked":
            await push(.kicked(byDisplayName: value["by_name"]?.stringValue ?? ""))
        case "error":
            history.refused()
        case "channel.closed":
            let code = value["code"]?.stringValue
            if code == "terminal.kicked" {
                let queue = self.queue
                stopAttach()
                await queue?.finish()
                return false
            }
            await end(TerminalLinkFailure(closeCode: code))
            return false
        default:
            break
        }
        return true
    }

    private func push(_ event: TerminalSourceEvent) async {
        await queue?.push(event, at: clock.now)
    }

    private func delivered(_ item: TerminalDeliveryQueue.Item) {
        monitor.frameDelivered(waited: clock.now - item.queuedAt)
        publishTelemetry()
    }

    // MARK: Phone to host

    func send(_ input: Data) async throws {
        await acquireInput()
        defer { releaseInput() }
        guard let channel else { throw TerminalLinkError.notConnected }
        let now = clock.now
        if let host = predictor.hostOffset { monitor.inputSent(hostOffset: host, at: now) }
        if let shown = predictor.input(input, rtt: monitor.effectiveRTT, now: now),
           let generation = predictor.generation, let offset = predictor.viewerOffset {
            monitor.predictionShown()
            await push(.frame(TerminalFrame(kind: .bytes, generation: generation, offset: offset, payload: shown)))
            armExpiry()
        }
        try await channel.send(binary: TerminalInput(kind: .bytes, data: input).encoded)
    }

    func viewportChanged(_ viewport: CmuxTerminalRenderCore.TerminalViewport) async {
        self.viewport = viewport
        guard channel != nil else { return }
        let visibilityChanged = sentVisible != viewport.visible
        sentVisible = viewport.visible
        let presence = ChannelMessage(name: "terminal.presence", body: [
            "visible": .bool(viewport.visible), "counts": .bool(viewport.visible),
        ])
        guard viewport.visible else {
            // A hidden phone stops counting; a size report would make it count
            // again (sizing corpus), so rotation while hidden waits.
            if visibilityChanged { await sendMessage(presence) }
            return
        }
        let grid = (cols: viewport.cols, rows: viewport.rows)
        if sentGrid.map({ $0.cols != grid.cols || $0.rows != grid.rows }) ?? true {
            sentGrid = grid
            await sendMessage(ChannelMessage(name: "terminal.viewport", body: [
                "viewport": .object(["cols": .int(Int64(grid.cols)), "rows": .int(Int64(grid.rows))]),
            ]))
        }
        if visibilityChanged { await sendMessage(presence) }
    }

    func requestSnapshot(_ request: SnapshotRequest) async {
        let have: JSONValue = request.have.map {
            .object(["generation": .int(Int64($0.generation)), "offset": .int(Int64($0.offset)),
                     "snapshot_version": .int(Int64($0.snapshotVersion))])
        } ?? .null
        await sendMessage(ChannelMessage(name: "terminal.snapshot_request", body: [
            "terminal": .string(request.terminal), "reason": .string(request.reason.rawValue), "have": have,
            "request_id": .string(request.requestID),
        ]))
    }

    /// The page before the oldest history this viewer holds, once at a time.
    func loadOlderHistory() async {
        guard history.canRequest, channel != nil else { return }
        history.requested()
        await requestHistory(before: history.oldestOffset, maxBytes: TerminalHistoryTracker.pageBytes)
    }

    func historyStates() -> AsyncStream<TerminalHistoryState> {
        history.subscribe { [weak self] id in Task { await self?.dropHistorySubscriber(id) } }
    }

    private func dropHistorySubscriber(_ id: UUID) {
        history.unsubscribe(id)
    }

    func requestHistory(before offset: UInt64?, maxBytes: Int) async {
        var body: [String: JSONValue] = ["max_bytes": .int(Int64(maxBytes))]
        body["before"] = offset.map { .int(Int64($0)) } ?? .null
        await sendMessage(ChannelMessage(name: "terminal.history", body: body))
    }

    private func sendMessage(_ message: ChannelMessage) async {
        try? await channel?.send(message: message)
    }

    private func acquireInput() async {
        guard inputBusy else {
            inputBusy = true
            return
        }
        await withCheckedContinuation { inputWaiters.append($0) }
    }

    private func releaseInput() {
        if inputWaiters.isEmpty {
            inputBusy = false
        } else {
            inputWaiters.removeFirst().resume()
        }
    }

    // MARK: Deadlines

    private func armExpiry() {
        cancelExpiry()
        guard let deadline = predictor.shownDeadline(rtt: monitor.effectiveRTT) else { return }
        let id = attachID
        let clock = self.clock
        let wait = deadline - clock.now
        expiryTask = Task { [weak self] in
            // wakeup-allow: one-shot prediction expiry (c1 section 8), injected clock, cancelled on confirm or close
            do { try await clock.sleep(for: max(wait, .zero)) } catch { return }
            await self?.predictionExpired(attach: id)
        }
    }

    private func cancelExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
    }

    private func predictionExpired(attach id: UInt64) async {
        guard id == attachID, predictor.shownDeadline(rtt: monitor.effectiveRTT) != nil else { return }
        monitor.predictionRolledBack()
        await resync()
        publishTelemetry()
    }

    private func armReadyDeadline() {
        readyTask?.cancel()
        let id = attachID
        let clock = self.clock
        let timeout = options.readyTimeout
        readyTask = Task { [weak self] in
            // wakeup-allow: one-shot READY deadline for the source's own snapshot request, injected clock
            do { try await clock.sleep(for: timeout) } catch { return }
            await self?.readyDeadlinePassed(attach: id)
        }
    }

    private func readyDeadlinePassed(attach id: UInt64) async {
        guard id == attachID, awaitingKeyframe else { return }
        await reattach()
    }

    // MARK: Telemetry

    func telemetry() -> AsyncStream<TerminalLatencyReport> {
        let (stream, continuation) = AsyncStream<TerminalLatencyReport>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        telemetrySubscribers[id] = continuation
        continuation.yield(monitor.report)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeTelemetrySubscriber(id) }
        }
        return stream
    }

    var report: TerminalLatencyReport { monitor.report }

    private func removeTelemetrySubscriber(_ id: UUID) {
        telemetrySubscribers[id] = nil
    }

    private func publishTelemetry() {
        let report = monitor.report
        for continuation in telemetrySubscribers.values { continuation.yield(report) }
    }

    private func followBadges() {
        guard badgeTask == nil else { return }
        let client = client
        badgeTask = Task { [weak self] in
            for await badge in await client.pathBadges() {
                guard !Task.isCancelled else { return }
                await self?.badge(badge)
            }
        }
    }

    private func badge(_ badge: PathBadge) async {
        monitor.linkRTT(badge.rtt)
        await push(.path(TerminalPath(badge.path.kind), rttMilliseconds: badge.rttMilliseconds))
        publishTelemetry()
    }

    static func failure(for error: any Error) -> TerminalLinkFailure {
        switch error as? MobileLinkClientError {
        case .helloRejected(let code, _)?: .unauthorized(code: code)
        case .refused(let code, _, _)?:
            code == "terminal.not_found" ? .notFound : (code.hasPrefix("auth.") ? .unauthorized(code: code) : .ended(code: code))
        default: .unreachable
        }
    }
}

private extension TerminalDeliveryQueue {
    nonisolated func finishDetached() {
        Task { await finish() }
    }
}
