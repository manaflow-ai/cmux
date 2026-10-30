public import Foundation

/// A sandboxed Run this app handed off (hq#3367), as the follower keeps it across a relaunch.
public nonisolated struct SandboxRunRecord: Codable, Hashable, Sendable {
    public var id: String
    /// The task as the person wrote it.
    public var task: String
    /// The page's attempt key (the create's idempotency key): which tab's send this Run is.
    public var key: String
    /// The signed-in user that created it: only that user's session may read it.
    public var user: String
    /// The team the create went to; the waits go there too.
    public var team: String?
    public var started: Date

    public init(id: String, task: String, key: String, user: String, team: String?, started: Date) {
        (self.id, self.task, self.key, self.user, self.team, self.started) = (id, task, key, user, team, started)
    }
}

/// A Run that ended here, kept across a relaunch for ``SandboxRunFollower/keptEnded``: a late
/// ``SandboxRunFollower/follow(_:)`` never tells it again, and its banner's click still finds its card.
public nonisolated struct SandboxRunEnded: Codable, Hashable, Sendable {
    public var record: SandboxRunRecord
    public var outcome: SandboxRunEnd.Outcome
    /// The final snapshot's receipt alone (`{"receipt": …}`), what the Run's card shows; nil when it had none.
    public var card: Data?
    public var at: Date
    /// Its end was told (``SandboxRunFollower/onEnd`` ran), or is never to be told (this app cancelled
    /// it). An end saved but not yet told is told at the next launch.
    public var told: Bool
}

/// How a followed Run ended.
public nonisolated struct SandboxRunEnd: Sendable {
    public enum Outcome: String, Codable, Sendable { case succeeded, failed, timedOut, cancelled }
    public var record: SandboxRunRecord
    public var outcome: Outcome
    /// The terminal snapshot (`{run, attempts, artifacts, receipt}`) as the server sent it; a
    /// replayed end carries the saved receipt alone (`{receipt}`).
    public var snapshot: Data
    /// Told again at a launch: the last launch saved the end but may have died around its banner.
    public var replayed = false

    public init(record: SandboxRunRecord, outcome: Outcome, snapshot: Data, replayed: Bool = false) {
        (self.record, self.outcome, self.snapshot, self.replayed) = (record, outcome, snapshot, replayed)
    }
}
