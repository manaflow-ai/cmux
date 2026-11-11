import CmuxNextWakeups
import Foundation

/// The `_acpmux/info` read of each session with a pending prompt, every read independent of the
/// others. Read one after another, one peer whose info handler stalled held every session listed
/// after it, this Mac's own prompts included (the queued-reads class of hq#9137: work that was
/// independent, serialized, so one slow item stalls unrelated ones). Here:
/// - this Mac's own sessions are read first, so no peer's read starts ahead of them;
/// - at most `width` reads run at once, each in its own slot;
/// - each read answers within its own `deadline`: a stalled one counts as no prompts and frees
///   its slot for the next session;
/// - a stalled read stays outstanding, and when its answer comes, `each` gets it then: a peer
///   that answers late still has its prompts posted, with no reconnect;
/// - a session has at most one outstanding read: a later pass that finds one joins it rather
///   than asking again. Asked again on every recovery, a peer that never answered held one more
///   read (and its line's reply continuation) each time, up to the 600 s peer wait (the class:
///   unbounded waiters after a timeout). Keyed by session, not peer: a join must get the same
///   question's answer, and another session of that peer asks another; so the reads one value
///   holds are at most the sessions it was asked for, however many passes ask again.
///
/// Reads are joined only within one value: the feed bridge keeps one for its life.
public nonisolated struct AcpmuxPendingReads: Sendable {
    /// How many reads run at once.
    public let width: Int
    /// How long one read may wait for its answer.
    public let deadline: Duration
    let clock: any Clock<Duration>
    /// The reads still waiting for their answer, by session.
    let outstanding = Outstanding()

    /// The feed bridge's recovery of prompts that predate its connection. 10 s is well past a
    /// healthy peer's info answer over its link (local ones answer in milliseconds), and bounds
    /// how long a stalled peer holds one of the four slots; nothing waits on the batch as a whole.
    /// Each use is a new value with its own outstanding reads: the bridge keeps the one it reads with.
    public static var feed: AcpmuxPendingReads { AcpmuxPendingReads(width: 4, deadline: .seconds(10)) }
    /// The dialog desk's list (`feed.list`): its whole connection lives 5 s
    /// (``AcpmuxPersonLine/open(_:deadline:)``), so one read gets 2 s and the list still answers.
    /// One per list, on that list's line: the desk closes the line once the list answers, which
    /// ends its reads, so a late answer there has no one to reach and nothing outlives the list.
    public static var dialog: AcpmuxPendingReads { AcpmuxPendingReads(width: 4, deadline: .seconds(2)) }

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
    /// as that read answers. A read that fails or passes the deadline gives no entries; one that
    /// passed it and answers later calls `each` again then, with what it found.
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
                    let info = await self.bounded(session, read) { late in
                        await each(next.index, next.row, late["pending"] as? [[String: Any]] ?? [])
                    }
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

    /// `read(session)`, or nil once `deadline` passes first. The session's outstanding read is
    /// joined when there is one, else started and kept until its connection answers or closes.
    /// An answer that comes after every pass waiting on it passed its deadline goes to `late`
    /// (the newest pass's): a late answer is delivered, not dropped.
    @MainActor
    func bounded(_ session: String, _ read: @escaping @MainActor (String) async -> [String: Any]?,
                 late: @escaping @MainActor ([String: Any]) async -> Void) async -> [String: Any]? {
        let outcome = FirstOutcome<ResultBox?>()
        let pending = outstanding.read(session, with: read)
        pending.waiters.append(outcome)
        pending.late = late
        let limit = DemandTimer(owner: "acpmux.pending-reads", clock: clock)
        limit.schedule(after: deadline) { outcome.resolve(nil) }
        defer { limit.cancel() }
        let answer = await outcome.value()?.value
        // A pass that took its deadline stops waiting: joins add no waiter that outlives its pass.
        pending.waiters.removeAll { $0 === outcome }
        return answer
    }

    /// The `_acpmux/info` reads still waiting for their answer, one per session.
    @MainActor
    final class Outstanding {
        /// One session's read: the passes waiting on it, and where an answer goes that comes
        /// after every one of them passed its deadline.
        @MainActor
        final class Read {
            var waiters: [FirstOutcome<ResultBox?>] = []
            var late: (@MainActor ([String: Any]) async -> Void)?
        }

        private var reads: [String: Read] = [:]

        nonisolated init() {}

        /// The outstanding read of `session`, started with `read` when it has none.
        func read(_ session: String, with read: @escaping @MainActor (String) async -> [String: Any]?) -> Read {
            if let running = reads[session] { return running }
            let started = Read()
            reads[session] = started
            // task-owner: the one info read of `session`; it ends with its line's reply or close, and passes while it runs join it.
            Task { [weak self] in
                let answer = await read(session)
                await self?.finish(session, started, answer)
            }
            return started
        }

        /// The read answered: every pass still waiting gets it; when none did, it goes to `late`.
        private func finish(_ session: String, _ done: Read, _ answer: [String: Any]?) async {
            if reads[session] === done { reads[session] = nil }
            let box = answer.map(ResultBox.init)
            // Every waiter is resolved (no short circuit); one that passed its deadline already took nil.
            let delivered = done.waiters.map { $0.resolve(box) }.contains(true)
            done.waiters = []
            guard !delivered, let answer, let late = done.late else { return }
            done.late = nil
            await late(answer)
        }
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
