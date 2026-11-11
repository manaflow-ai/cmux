import CmuxNextWakeups
import Foundation

/// The `_acpmux/info` read of each session with a pending prompt, every read independent of the
/// others. Read one after another, one peer whose info handler stalled held every session listed
/// after it, this Mac's own prompts included (the queued-reads class of hq#9137: work that was
/// independent, serialized, so one slow item stalls unrelated ones). Here:
/// - this Mac's own sessions are read first, so no peer's read starts ahead of them;
/// - at most `width` reads run at once, each in its own slot;
/// - each read answers within its own `deadline`: a stalled one counts as no prompts and frees
///   its slot for the next session.
public nonisolated struct AcpmuxPendingReads: Sendable {
    /// How many reads run at once.
    public let width: Int
    /// How long one read may wait for its answer.
    public let deadline: Duration
    let clock: any Clock<Duration>

    /// The feed bridge's recovery of prompts that predate its connection. 10 s is well past a
    /// healthy peer's info answer over its link (local ones answer in milliseconds), and bounds
    /// how long a stalled peer holds one of the four slots; nothing waits on the batch as a whole.
    public static let feed = AcpmuxPendingReads(width: 4, deadline: .seconds(10))
    /// The dialog desk's list (`feed.list`): its whole connection lives 5 s
    /// (``AcpmuxPersonLine/open(_:deadline:)``), so one read gets 2 s and the list still answers.
    public static let dialog = AcpmuxPendingReads(width: 4, deadline: .seconds(2))

    public init(width: Int, deadline: Duration, clock: any Clock<Duration> = ContinuousClock()) {
        self.width = max(1, width)
        self.deadline = deadline
        self.clock = clock
    }

    /// Whether a `_acpmux/sessions` row is this daemon's own session: one with no `peer`.
    public static func isLocal(_ row: [String: Any]) -> Bool {
        (row["peer"] as? String)?.isEmpty != false
    }

    /// `rows` with this daemon's own sessions first, each group in its listed order.
    public static func localFirst(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.filter(isLocal) + rows.filter { !isLocal($0) }
    }

    /// Reads each row's `_acpmux/info` with `read` (its session id), local first, and calls
    /// `each` with the row's place in ``localFirst(_:)``, the row and its pending entries as soon
    /// as that read answers. A read that fails or passes the deadline gives no entries.
    @MainActor
    public func forEach(_ rows: [[String: Any]],
                        read: @escaping @MainActor (String) async -> [String: Any]?,
                        each: @escaping @MainActor (Int, [String: Any], [[String: Any]]) async -> Void) async {
        let queue = Queue(Self.localFirst(rows))
        let slots = min(width, queue.count)
        guard slots > 0 else { return }
        // One task per slot, awaited below (a task group here trips Swift 6.2's region checker).
        // task-owner: forEach awaits every slot before it returns; each slot ends when the queue is empty.
        var workers: [Task<Void, Never>] = []
        for _ in 0..<slots {
            workers.append(Task {
                while let next = queue.take() {
                    guard let session = next.row["sessionId"] as? String, !session.isEmpty else { continue }
                    let info = await self.bounded(session, read)
                    await each(next.index, next.row, info?["pending"] as? [[String: Any]] ?? [])
                }
            })
        }
        for worker in workers { await worker.value }
    }

    /// ``forEach(_:read:each:)`` for each pending prompt: `each` gets its session, its
    /// `permissionId` and its `request`.
    @MainActor
    public func forEachPrompt(_ rows: [[String: Any]], read: @escaping @MainActor (String) async -> [String: Any]?,
                              each: @escaping @MainActor (String, String, [String: Any]) async -> Void) async {
        await forEach(rows, read: read) { _, row, entries in
            guard let session = row["sessionId"] as? String else { return }
            for prompt in Self.prompts(entries) { await each(session, prompt.permission, prompt.request) }
        }
    }

    /// The prompts of `_acpmux/info`'s `pending` entries that name a permission and a request.
    public static func prompts(_ entries: [[String: Any]]) -> [(permission: String, request: [String: Any])] {
        entries.compactMap { entry in
            guard let permission = entry["permissionId"] as? String, let request = entry["request"] as? [String: Any] else { return nil }
            return (permission, request)
        }
    }

    /// Each row with its pending entries, read as ``forEach(_:read:each:)`` reads them, in
    /// ``localFirst(_:)`` order once every read answered or passed its deadline.
    @MainActor
    public func pending(of rows: [[String: Any]], read: @escaping @MainActor (String) async -> [String: Any]?)
        async -> [(row: [String: Any], pending: [[String: Any]])] {
        let found = Found()
        await forEach(rows, read: read) { index, row, pending in found.rows[index] = (row, pending) }
        return found.rows.keys.sorted().compactMap { found.rows[$0] }
    }

    /// `read(session)`, or nil once `deadline` passes first. A late answer is dropped; the read
    /// itself ends when its connection answers or closes.
    @MainActor
    func bounded(_ session: String, _ read: @escaping @MainActor (String) async -> [String: Any]?) async -> [String: Any]? {
        let outcome = FirstOutcome<ResultBox?>()
        let limit = DemandTimer(owner: "acpmux.pending-reads", clock: clock)
        limit.schedule(after: deadline) { outcome.resolve(nil) }
        defer { limit.cancel() }
        // task-owner: one info read; it ends with its line's reply or close, and the deadline answers first when it stalls.
        Task { outcome.resolve((await read(session)).map(ResultBox.init)) }
        return await outcome.value()?.value
    }

    /// What each read found, by its row's place.
    @MainActor
    private final class Found {
        var rows: [Int: (row: [String: Any], pending: [[String: Any]])] = [:]
    }

    /// The rows still to read, taken in order by every slot.
    @MainActor
    private final class Queue {
        let count: Int
        private var rest: ArraySlice<(index: Int, row: [String: Any])>
        init(_ rows: [[String: Any]]) {
            count = rows.count
            rest = ArraySlice(rows.enumerated().map { (index: $0.offset, row: $0.element) })
        }

        func take() -> (index: Int, row: [String: Any])? { rest.popFirst() }
    }
}
