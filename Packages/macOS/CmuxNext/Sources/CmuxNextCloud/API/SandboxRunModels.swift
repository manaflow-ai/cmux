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
    /// The source's position after the last wait (a hand-off's version), so a wait passes it.
    public var cursor: Int?
    /// The notices already told (``CloudTaskNotice/key``, newest last, bounded): each is told once.
    public var told: [String]?
    /// When the task last changed (its cursor moved, or a hand-off's listing showed its last change);
    /// ``SandboxRunFollower/Source/maximumAge`` counts from here (nil: from ``started``).
    public var changed: Date?
    /// Its current turn runs (a hand-off `starting` or `running`), as last read: not given up for
    /// ``SandboxRunFollower/Source/maximumAge`` since it changed, only for that long without an answer.
    public var running: Bool?
    /// The acpmux host of a hand-off's chat, when this app made it (nil: unknown).
    public var host: String?
    /// Sent from an incognito window's chat: never saved for the next launch, and its banner names nothing.
    public var incognito: Bool?

    public init(id: String, task: String, key: String, user: String, team: String?, started: Date) {
        (self.id, self.task, self.key, self.user, self.team, self.started) = (id, task, key, user, team, started)
    }
}

/// One wait's answer, as a ``SandboxRunFollower/Source`` reads it.
public nonisolated enum CloudTaskRead: Sendable {
    /// Still going; the next wait passes `cursor`. A `notice` is told once per its key. `running`:
    /// its current turn runs, so it is not given up for age (``SandboxRunRecord/running``).
    case going(cursor: Int?, notice: CloudTaskNotice?, Data, running: Bool = false)
    /// A Run's end: told by the follower's rules (``SandboxRunFollower/noteCancel(_:)``).
    case ended(SandboxRunEnd.Outcome, Data)
    /// It will not change again (a hand-off closed): its `notice`, if not told yet, is told, then
    /// the follow ends without telling more.
    case closed(notice: CloudTaskNotice?, Data)
    /// No answer of the source's shape: never an end.
    case unreadable
}

/// Something to tell about a task that goes on (a hand-off's turn done, failed or waiting for
/// the person): told once per `key`, so the same state read again tells nothing.
public nonisolated struct CloudTaskNotice: Hashable, Sendable {
    /// What makes it the same notice (a hand-off's turn and status, `"2:done"`).
    public var key: String
    public var outcome: SandboxRunEnd.Outcome

    public init(key: String, outcome: SandboxRunEnd.Outcome) { (self.key, self.outcome) = (key, outcome) }
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
    /// `needsYou` is no end: the task waits for the person and goes on after (a hand-off's notice).
    public enum Outcome: String, Codable, Sendable { case succeeded, failed, timedOut, cancelled, needsYou }
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
