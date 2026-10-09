import CmuxMobileWire
import Foundation

/// Projects the Mac's task runner into `task:<host>` (c8-composer.md 2): a
/// snapshot of agents and the newest tasks, `task.state.set` events for state
/// transitions, and a fresh snapshot at the next seq for anything else (a new
/// task, a changed agent list). The runner owns the records; this actor only
/// diffs consecutive reads.
///
/// Seq starts at the process start in Unix milliseconds and every frame
/// carries `epoch`, as `WorkspaceStreamOwner` does. Refreshes run on the
/// runner's change signals, coalesced; no timer.
public actor TaskStreamOwner: MobileStreamOwner {
    public nonisolated let stream: String
    public nonisolated let hostID: String
    public nonisolated let epoch: String
    private let runner: any MobileTaskRunner
    private let tailLimit: Int
    private let subscriberBuffer: Int
    private let now: @Sendable () -> Date
    private var state: MobileTaskStreamState?
    private var head: UInt64
    /// Seq of the newest snapshot; events after it are in `tail`.
    private var snapshotSeq: UInt64
    private var tail: [EventFrame] = []
    private var subscribers: [UUID: AsyncStream<WorkspaceStreamUpdate>.Continuation] = [:]
    private var changeTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var stopped = false

    public init(hostID: String, runner: any MobileTaskRunner, startSeq: UInt64? = nil, tailLimit: Int = 256,
                subscriberBuffer: Int = 256, now: @escaping @Sendable () -> Date = { Date() }) {
        self.hostID = hostID
        stream = "task:\(hostID)"
        self.runner = runner
        self.tailLimit = max(1, tailLimit)
        self.subscriberBuffer = max(1, subscriberBuffer)
        self.now = now
        let start = startSeq ?? UInt64(max(0, now().timeIntervalSince1970 * 1000))
        head = start
        snapshotSeq = start
        epoch = "ep_\(start)_\(UUID().uuidString.prefix(8).lowercased())"
    }

    public nonisolated func stamped(_ frame: MobileFrame) throws -> JSONValue {
        guard case .object(var object) = try frame.jsonValue else { return try frame.jsonValue }
        object["epoch"] = .string(epoch)
        return .object(object)
    }

    public var headSeq: UInt64 { head }

    public func currentState() async throws -> MobileTaskStreamState {
        if let state { return state }
        if changeTask == nil, !stopped {
            let changes = await runner.changes()
            changeTask = Task { [weak self] in
                for await _ in changes {
                    guard let self, !Task.isCancelled else { return }
                    await self.refresh()
                }
            }
        }
        let loaded = try await read()
        if let state { return state }
        state = loaded
        return loaded
    }

    public func snapshotFrame(decided: [DecidedKey] = []) async throws -> SnapshotFrame {
        let current = try await currentState()
        return SnapshotFrame(stream: stream, seq: head, state: try current.jsonValue, decided: decided, epoch: epoch)
    }

    public func updates(afterSeq: UInt64?, epoch: String? = nil) async throws -> AsyncStream<WorkspaceStreamUpdate> {
        let snapshot = try await snapshotFrame()
        let (stream, continuation) = AsyncStream<WorkspaceStreamUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(subscriberBuffer))
        let floor = tail.first?.seq ?? head + 1
        if let after = afterSeq, epoch == nil || epoch == self.epoch, after >= snapshotSeq, after <= head,
           after + 1 >= floor || after == head {
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
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    /// Re-reads the runner and commits the differences. Returns after a read
    /// that started after this call.
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

    private func read() async throws -> MobileTaskStreamState {
        let agents = try await runner.agents()
        let tasks = try await runner.tasks()
        return MobileTaskStreamState(agents: agents, tasks: tasks).bounded
    }

    private func refreshLoop() async {
        repeat {
            refreshAgain = false
            await readOnce()
        } while refreshAgain && !stopped
        refreshTask = nil
    }

    private func readOnce() async {
        guard let old = state else { return }
        guard let new = try? await read(), new != old else { return }
        state = new
        let structural = old.agents != new.agents || old.tasks.map(\.structure) != new.tasks.map(\.structure)
        if structural {
            head += 1
            snapshotSeq = head
            tail.removeAll()
            guard let value = try? new.jsonValue else { return }
            let snapshot = SnapshotFrame(stream: stream, seq: head, state: value, decided: [], epoch: epoch)
            for continuation in subscribers.values { continuation.yield(.snapshot(snapshot)) }
            return
        }
        let at = Int64(now().timeIntervalSince1970 * 1000)
        for (before, after) in zip(old.tasks, new.tasks) where before.state != after.state {
            head += 1
            var params: [String: JSONValue] = ["task": .string(after.id), "state": .string(after.state.rawValue), "at": .int(at)]
            if let tab = after.tab { params["tab"] = .string(tab) }
            let event = EventFrame(stream: stream, seq: head, tx: "tx_\(hostID)_task_\(head)", op: "task.state.set",
                                   params: .object(params), actor: ["identity": .string("host:\(hostID)")],
                                   origin: .cli, at: at, epoch: epoch)
            tail.append(event)
            if tail.count > tailLimit { tail.removeFirst(tail.count - tailLimit) }
            for continuation in subscribers.values { continuation.yield(.event(event)) }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
