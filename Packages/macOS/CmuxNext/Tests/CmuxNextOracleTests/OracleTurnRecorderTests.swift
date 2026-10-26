#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextOracle
import Testing

/// The turn recorder (p15-oracle-032): armed, it hashes the armed main-actor facets at each turn end,
/// so a turn's hash shows what changed in that turn and equals the settled mark when nothing changed
/// after (invariant I3); disarmed it records nothing; a facet read off the main actor cannot be armed.
/// Run: `swift test --filter OracleTurnRecorderTests`.
@MainActor @Suite struct OracleTurnRecorderTests {
    /// The model a fake topology facet reads.
    @MainActor final class Model {
        var panes = 1
        var fails = false
    }

    private func facets(_ model: Model) -> OracleFacets {
        OracleFacets([
            OracleFacetSource(.topology, .mainActor { () throws(OracleFacetError) -> OracleValue in
                ["panes": OracleValue(model.panes)]
            }),
            OracleFacetSource(.terminals, .background { () async throws(OracleFacetError) -> OracleValue in
                ["count": 0]
            }),
        ])
    }

    @Test func aTurnHashesWhatChangedInItAndEqualsTheSettledMark() throws {
        let model = Model()
        let recorder = OracleTurnRecorder()
        let armed = try recorder.arm(facets(model), requested: [.topology])

        model.panes += 1
        recorder.turnEnded(action: "pane.splitRight", origin: "cli", ran: true)
        let settled = try recorder.mark("settled")

        let checkpoints = recorder.ring.checkpoints()
        #expect(checkpoints.map(\.kind) == [.mark, .turn, .mark])
        #expect(checkpoints.map(\.label) == ["armed", "pane.splitRight", "settled"])
        let turn = checkpoints[1]
        #expect(turn.origin == "cli")
        #expect(turn.ran == true)
        #expect(turn.snapshot != armed.snapshot)
        #expect(turn.snapshot == settled.snapshot)
        #expect(turn.snapshot == OracleSnapshotHash(["topology": ["panes": 2]]))
    }

    @Test func aDisarmedRecorderRecordsNothing() throws {
        let model = Model()
        let recorder = OracleTurnRecorder()
        recorder.turnEnded(action: "a", origin: "user", ran: true)
        #expect(recorder.ring.checkpoints().isEmpty)
        #expect(throws: OracleRecorderError.notArmed) { try recorder.mark("settled") }

        try recorder.arm(facets(model), requested: [.topology])
        recorder.disarm()
        recorder.turnEnded(action: "a", origin: "user", ran: true)
        #expect(recorder.ring.checkpoints().map(\.label) == ["armed"])
    }

    @Test func aBackgroundFacetCannotBeArmed() {
        let recorder = OracleTurnRecorder()
        #expect(throws: OracleRecorderError.backgroundFacet) {
            try recorder.arm(facets(Model()), requested: [.topology, .terminals])
        }
        #expect(!recorder.isArmed)
        #expect(recorder.ring.checkpoints().isEmpty)
    }

    @Test func aFailingProviderIsRecordedAsAFailureNotAHash() throws {
        let model = Model()
        let facets = OracleFacets([
            OracleFacetSource(.topology, .mainActor { () throws(OracleFacetError) -> OracleValue in
                if model.fails { throw OracleFacetError("tree gone") }
                return ["panes": OracleValue(model.panes)]
            }),
        ])
        let recorder = OracleTurnRecorder()
        try recorder.arm(facets, requested: [.topology])
        model.fails = true
        recorder.turnEnded(action: "a", origin: "user", ran: true)
        let turn = try #require(recorder.ring.checkpoints().last)
        #expect(turn.snapshot == nil)
        #expect(turn.failure == "facet topology: tree gone")
    }

    @Test func aFacetWithNoProviderIsHashedAsNotComparable() throws {
        let recorder = OracleTurnRecorder()
        let armed = try recorder.arm(OracleFacets([]), requested: [.focus])
        let expected = OracleSnapshotHash(["focus": .notComparable(reason: "no provider for focus in this build",
                                                                     task: OracleFacet.focus.task)])
        #expect(armed.snapshot == expected)
        #expect(recorder.status["armed"] == true)
        #expect(recorder.status["facets"] == ["focus"])
    }
}
#endif
