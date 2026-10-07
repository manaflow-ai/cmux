import CmuxMobileWire
import Foundation

/// Projects the daemon's tree into the `workspace:<host>` stream (seq, owner
/// events, bounded tail) for link subscribers and the `HostDO` uplink.
///
/// The daemon owns the layout; this actor only diffs consecutive daemon
/// states. Seq starts at the process start in Unix milliseconds, so a
/// restarted host never reuses a seq a mirror holds (b5-mac-host.md 5).
/// Refreshes run on daemon change signals, coalesced: a signal during a read
/// schedules one more read, never a timer.
public actor WorkspaceStreamOwner {
    public nonisolated let stream: String
    public nonisolated let hostID: String
    private let daemon: any MobileDaemon
    private let tailLimit: Int
    private let subscriberBuffer: Int
    private let now: @Sendable () -> Date
    private var state: MobileWorkspaceState?
    private var head: UInt64
    private var tail: [EventFrame] = []
    private var subscribers: [UUID: AsyncStream<WorkspaceStreamUpdate>.Continuation] = [:]
    private var loadTask: Task<MobileWorkspaceState, any Error>?
    private var changeTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var stopped = false

    public init(hostID: String, daemon: any MobileDaemon, startSeq: UInt64? = nil, tailLimit: Int = 512,
                subscriberBuffer: Int = 1024, now: @escaping @Sendable () -> Date = { Date() }) {
        self.hostID = hostID
        stream = "workspace:\(hostID)"
        self.daemon = daemon
        self.tailLimit = max(1, tailLimit)
        self.subscriberBuffer = max(1, subscriberBuffer)
        self.now = now
        head = startSeq ?? UInt64(max(0, now().timeIntervalSince1970 * 1000))
    }

    /// The seq of the last committed event (or of the starting snapshot).
    public var headSeq: UInt64 { head }

    /// The current projected state, loading it on first use.
    public func currentState() async throws -> MobileWorkspaceState {
        if let state { return state }
        return try await load()
    }

    public func snapshotFrame(decided: [DecidedKey] = []) async throws -> SnapshotFrame {
        _ = try await currentState()
        return try loadedSnapshot(decided: decided)
    }

    /// Updates from now on. With `afterSeq` inside the retained tail the
    /// stream starts with the missed events; otherwise with a snapshot.
    /// A subscriber more than `subscriberBuffer` updates behind loses the
    /// newest ones and sees a seq jump (resync with a snapshot).
    public func updates(afterSeq: UInt64?) async throws -> AsyncStream<WorkspaceStreamUpdate> {
        _ = try await currentState()
        // No suspension from here to the registration: the initial items and
        // the live events meet exactly at `head`.
        let snapshot = try loadedSnapshot(decided: [])
        let (stream, continuation) = AsyncStream<WorkspaceStreamUpdate>.makeStream(
            bufferingPolicy: .bufferingOldest(subscriberBuffer))
        let floor = tail.first?.seq ?? head + 1
        if let after = afterSeq, after <= head, after + 1 >= floor {
            for event in tail where event.seq > after { continuation.yield(.event(event)) }
        } else {
            continuation.yield(.snapshot(snapshot))
        }
        if stopped {
            continuation.finish()
            return stream
        }
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    /// Re-reads the daemon and commits the differences as events. Returns
    /// after a read that started after this call.
    public func refresh() async {
        if let running = refreshTask {
            refreshAgain = true
            await running.value
            return
        }
        let task = Task { await self.refreshLoop() }
        refreshTask = task
        await task.value
    }

    public func stop() {
        stopped = true
        changeTask?.cancel()
        changeTask = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    // MARK: Private

    private func loadedSnapshot(decided: [DecidedKey]) throws -> SnapshotFrame {
        guard let state else { throw MobileDaemonError(code: "owner.unreachable", message: "workspace state not loaded", retryable: true) }
        return SnapshotFrame(stream: stream, seq: head, state: try state.jsonValue, decided: decided)
    }

    private func load() async throws -> MobileWorkspaceState {
        if let loadTask { return try await loadTask.value }
        let daemon = daemon
        let task = Task { try await daemon.workspaceState() }
        loadTask = task
        do {
            let loaded = try await task.value
            if state == nil {
                state = loaded
                startListening()
            }
            return state ?? loaded
        } catch {
            loadTask = nil
            throw error
        }
    }

    private func startListening() {
        guard changeTask == nil, !stopped else { return }
        let daemon = daemon
        changeTask = Task { [weak self] in
            for await _ in await daemon.workspaceChanges() {
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    private func refreshLoop() async {
        repeat {
            refreshAgain = false
            await readOnce()
        } while refreshAgain && !stopped
        refreshTask = nil
    }

    private func readOnce() async {
        guard let old = state, let new = try? await daemon.workspaceState() else { return }
        let changes = WorkspaceDiff(from: old, to: new).changes
        state = new
        let at = Int64(now().timeIntervalSince1970 * 1000)
        for change in changes {
            head += 1
            let event = EventFrame(stream: stream, seq: head, tx: "tx_\(hostID)_\(head)", op: change.op,
                                   params: change.params, actor: ["identity": .string("host:\(hostID)")],
                                   origin: .cli, at: at)
            tail.append(event)
            if tail.count > tailLimit { tail.removeFirst(tail.count - tailLimit) }
            for continuation in subscribers.values { continuation.yield(.event(event)) }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
