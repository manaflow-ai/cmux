#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Testing

/// The invariants facet: the check's violation ids, the window problems and the check count in
/// the schema's shape, read in the snapshot's main-actor turn; with no monitor it is not-comparable with its task,
/// never an empty pass. Run: `swift test --filter OracleInvariantsFacetTests`.
@MainActor
struct OracleInvariantsFacetTests {
    @Test func aCheckIsTheSchemasObject() throws {
        let facet = OracleInvariantsFacet {
            OracleInvariantsFacet.Reading(violations: ["F2", "W3", "F2"], windowInvariants: ["window w1 has 0 workspaces"], checks: 7)
        }
        #expect(facet.facet == .invariants)
        let snapshot = try #require(try OracleFacets([facet]).beginCapture([.invariants]).completed)
        #expect(snapshot["invariants"] == [
            "violations": ["F2", "W3", "F2"],
            "windowInvariants": ["window w1 has 0 workspaces"],
            "checks": 7,
        ])
    }

    @MainActor final class Monitor {
        var checks = 0
    }

    @Test func eachSnapshotRunsTheCheckAgain() throws {
        let monitor = Monitor()
        let facet = OracleInvariantsFacet {
            monitor.checks += 1
            return OracleInvariantsFacet.Reading(violations: [], windowInvariants: [], checks: monitor.checks)
        }
        let facets = OracleFacets([facet])
        _ = try facets.beginCapture([.invariants])
        let second = try #require(try facets.beginCapture([.invariants]).completed)
        #expect(second["invariants"]?["checks"] == 2)
    }

    @Test func noMonitorIsNotComparable() throws {
        let snapshot = try #require(try OracleFacets([OracleInvariantsFacet { nil }]).beginCapture([.invariants]).completed)
        #expect(snapshot["invariants"]?["status"] == "not-comparable")
        #expect(snapshot["invariants"]?["task"] == "p15-oracle-033")
    }
}
#endif
