#if DEBUG || CMUX_BENCH_HOOKS
/// What ran the check that found a violation (plans/cmux-next/invariants-DESIGN.md section 2.2).
public struct InvariantTrigger: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// The commit of a turn in which an action ran.
        case action
        /// The commit of a turn that touched a key the rule reads.
        case turn
        /// A call-site checker (``InvariantProbe/fail(_:_:_:fileID:line:)``).
        case inline
        /// A liveness rule's limit came with nothing else to check.
        case liveness
        /// `debug.invariants {check: true}` or a test's ``InvariantRegistry/checkNow(ids:)``.
        case check
    }

    public let kind: Kind
    /// The actions of the turn, in run order (at most ``InvariantRegistry/actionsKept``); for a check or an inline
    /// report, the last ones that ran.
    public let actions: [InvariantActionCause]
    /// The registry's pass number.
    public let turn: UInt64
    /// The display frame of the turn; nil until the frame adapter (`DisplayClock.displayDidFire`) is wired.
    public let frameSeq: UInt64?
    /// The call site of an inline report.
    public let fileID: String?
    public let line: UInt?

    public init(kind: Kind, actions: [InvariantActionCause], turn: UInt64, frameSeq: UInt64? = nil,
                fileID: String? = nil, line: UInt? = nil) {
        self.kind = kind
        self.actions = actions
        self.turn = turn
        self.frameSeq = frameSeq
        self.fileID = fileID
        self.line = line
    }
}
#endif
