#if DEBUG || CMUX_BENCH_HOOKS
/// Whether the checks run by themselves (plans/cmux-next/invariants-DESIGN.md section 2.1), from
/// `CMUX_NEXT_INVARIANTS` at launch: a Debug build is always armed; a bench build, which times like Release, is
/// armed only with `=1`. `CMUX_NEXT_FOCUS_CHECK=1`, the focus checker's opt-in, is an alias of `=1` for one train.
/// The design's `=trap` (stop at the first violation) is not built: a trap needs its crash-allowlist entry first.
public enum InvariantMode: String, Hashable, Sendable {
    /// Not armed: no turn runs a rule (a harness may still check on demand).
    case off
    /// Armed: every turn with an action or a touched key runs the rules due.
    case on

    public static let environmentKey = "CMUX_NEXT_INVARIANTS"
    /// The focus checker's bench opt-in (`=1`), kept for one train.
    public static let focusCheckAlias = "CMUX_NEXT_FOCUS_CHECK"

    public init(environment: [String: String]) {
        #if DEBUG
        self = .on
        #else
        let value = environment[Self.environmentKey] ?? environment[Self.focusCheckAlias]
        self = value == "1" ? .on : .off
        #endif
    }

    /// Whether turns run the rules.
    public var isArmed: Bool { self != .off }
}
#endif
