/// Whether the store holds a command's result after its reply (``DaemonService/appliedThroughReply(on:after:)``).
///
/// Only ``held`` lets a caller read the store for the result. Every other case means the command went through
/// (its reply came) but the store may lack what it changed: a CLI or `action.run` caller answers a typed failure
/// (``ActionWorkFailure/resultNotShown``), a person's action shows ``RefusalStrings/resultNotShown``.
public nonisolated enum AppliedThroughReply: Sendable, Equatable {
    /// The store applied every event the daemon emitted before the reply.
    case held
    /// The connection had no event sequence after the reply (it lost `ready`): nothing bounds the events, and
    /// no barrier on the service's current connection could be taken.
    case noSequence
    /// The connection is not this service's any more, or it ended (dropped before the store got there, marked
    /// failed, closed) during the wait, and the barrier on the service's current connection did not hold
    /// either: the command's events may never apply.
    case connectionChanged
    /// The waiting task was cancelled (a newer reopen cancels the last one's watch). Not logged.
    case cancelled

    /// Whether the store holds the command's result.
    public var isHeld: Bool { self == .held }
}
