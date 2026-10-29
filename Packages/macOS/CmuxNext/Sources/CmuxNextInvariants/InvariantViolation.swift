#if DEBUG || CMUX_BENCH_HOOKS
public import Foundation

/// One reported violation in the ledger (plans/cmux-next/invariants-DESIGN.md section 2.2): a signature
/// (`id@host@subject`) seen for the first time since it was last clear.
public struct InvariantViolation: Hashable, Sendable {
    /// The largest rule state the ledger keeps (the report file keeps the whole state).
    public static let stateLimit = 4096

    /// The ledger's sequence number (1 first, never reused).
    public let seq: UInt64
    public let id: InvariantID
    /// `app` or `daemon`.
    public let host: String
    public let subject: InvariantSubject
    public let detail: String
    public let trigger: InvariantTrigger
    /// The rule's read state as sorted-key JSON when it is at most ``stateLimit`` bytes, else nil.
    public let state: Data?
    /// The input journal's last sequence number once the app journaled the violation.
    public internal(set) var journalTail: UInt64?
    /// The report file's path once the app named it.
    public internal(set) var report: String?

    public init(seq: UInt64, id: InvariantID, host: String, subject: InvariantSubject, detail: String,
                trigger: InvariantTrigger, state: Data?) {
        self.seq = seq
        self.id = id
        self.host = host
        self.subject = subject
        self.detail = detail
        self.trigger = trigger
        self.state = state
    }

    /// One signature is reported once until a later check of its rule finds it clear.
    public var signature: String { "\(id.rawValue)@\(host)@\(subject)" }
}
#endif
