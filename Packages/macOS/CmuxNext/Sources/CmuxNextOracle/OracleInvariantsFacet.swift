#if DEBUG || CMUX_BENCH_HOOKS
/// The `invariants` facet (schemas/oracle/snapshot-v1.schema.json): the ids the input invariant check
/// finds broken now, the window invariants' problems, and how many checks ran. The host reads them in the
/// snapshot's main-actor turn: the input check `debug.desync` runs (`InputInvariantMonitor.check()`) and the
/// window problems `debug.focus` and `debug.windows` report (`WindowInvariants`); this type only gives them
/// the schema's shape.
public struct OracleInvariantsFacet: OracleFacetProvider {
    /// One check's result.
    public struct Reading: Sendable, Hashable {
        /// The id of each broken input invariant (`F1`, `W3`, ...), once per violation.
        public var violations: [String]
        public var windowInvariants: [String]
        /// Checks run since launch, this one included.
        public var checks: Int

        public init(violations: [String], windowInvariants: [String], checks: Int) {
            self.violations = violations
            self.windowInvariants = windowInvariants
            self.checks = checks
        }

        /// The facet's object.
        public var value: OracleValue {
            [
                "violations": .array(violations.map(OracleValue.string)),
                "windowInvariants": .array(windowInvariants.map(OracleValue.string)),
                "checks": OracleValue(checks),
            ]
        }
    }

    public var facet: OracleFacet { .invariants }
    public let capture: OracleFacetCapture

    /// - Parameter check: Runs the checks now; nil when this process has no invariant monitor (not started),
    ///   which answers not-comparable.
    public init(check: @escaping @MainActor @Sendable () -> Reading?) {
        capture = .mainActor { () throws(OracleFacetError) -> OracleValue in
            guard let reading = check() else {
                return .notComparable(reason: "no input invariant monitor in this process", task: OracleFacet.invariants.task)
            }
            return reading.value
        }
    }
}
#endif
