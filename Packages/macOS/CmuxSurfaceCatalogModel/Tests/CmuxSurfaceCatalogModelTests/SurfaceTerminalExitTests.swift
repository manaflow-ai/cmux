import Foundation
import Testing
@testable import CmuxSurfaceCatalogModel

/// A failed agent run whose tab closed used to vanish from the Cloud tree: the
/// snapshot parser dropped every tabless exited terminal. A failed one now
/// stays, carrying its exit receipt, so the tree can explain the failure.
@Suite struct SurfaceTerminalExitTests {
    private static let machine = SurfaceMachineID.cloud("vm-1")

    private static func exitedTerminal(id: String, outcome: [String: Any], tabIDs: [String] = []) -> [String: Any] {
        [
            "id": id,
            "tab_ids": tabIDs,
            "title": "claude",
            "cols": 80,
            "rows": 24,
            "running": false,
            "lifecycle": "exited",
            "exit": ["outcome": outcome, "exited_at": "1700000000000", "revision": "7"],
        ]
    }

    @Test func parsesExitCodeSignalAndUnknownOutcomes() throws {
        let code = try #require(SurfaceTerminalExit(receipt: ["outcome": ["kind": "exit", "code": 1], "exited_at": "1700000000000"]))
        #expect(code.kind == .exit)
        #expect(code.code == 1)
        #expect(code.isFailure)
        #expect(code.exitedAt == Date(timeIntervalSince1970: 1_700_000_000))

        let clean = try #require(SurfaceTerminalExit(receipt: ["outcome": ["kind": "exit", "code": 0]]))
        #expect(!clean.isFailure)

        let signal = try #require(SurfaceTerminalExit(receipt: ["state": "exited", "outcome": ["kind": "signal", "signal": 9, "core_dumped": false]]))
        #expect(signal.kind == .signal)
        #expect(signal.signal == 9)
        #expect(signal.isFailure)

        let unknown = try #require(SurfaceTerminalExit(receipt: ["outcome": ["kind": "unknown", "reason": "host lost"]]))
        #expect(unknown.reason == "host lost")
        #expect(unknown.isFailure)

        #expect(SurfaceTerminalExit(receipt: ["state": "pending"]) == nil)
        #expect(SurfaceTerminalExit(receipt: nil) == nil)
    }

    @Test func failedTablessRunStaysListedAndCleanOneDoesNot() throws {
        let snapshot: [String: Any] = [
            "terminals": [
                Self.exitedTerminal(id: "term_failed", outcome: ["kind": "exit", "code": 1]),
                Self.exitedTerminal(id: "term_clean", outcome: ["kind": "exit", "code": 0]),
            ],
        ]
        let resources = CmuxTuiSnapshotParser.terminals(fromSnapshot: snapshot, machine: Self.machine)
        #expect(resources.map(\.id.key) == ["term_failed"])
        let failed = try #require(resources.first)
        #expect(failed.lifecycle == .exited)
        #expect(failed.exit?.code == 1)
        #expect(failed.isFailedExitedTerminal)
        #expect(!failed.isDetachedTerminal)
    }

    @Test func outOfRangeOrFractionalNumbersParseAsAbsentInsteadOfTrapping() throws {
        let huge = try #require(SurfaceTerminalExit(receipt: [
            "outcome": ["kind": "exit", "code": 1e300],
            "exited_at": Double.greatestFiniteMagnitude,
        ]))
        #expect(huge.code == nil)
        #expect(huge.exitedAtMilliseconds == nil)
        let infinite = try #require(SurfaceTerminalExit(receipt: ["outcome": ["kind": "signal", "signal": Double.infinity]]))
        #expect(infinite.signal == nil)
        let fractional = try #require(SurfaceTerminalExit(receipt: ["outcome": ["kind": "exit", "code": 1.5]]))
        #expect(fractional.code == nil)
        let whole = try #require(SurfaceTerminalExit(receipt: ["outcome": ["kind": "exit", "code": 2.0], "exited_at": 1_700_000_000_000.0]))
        #expect(whole.code == 2)
        #expect(whole.exitedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func runningTerminalCarriesNoExit() {
        let entry: [String: Any] = ["id": "term_live", "running": true, "lifecycle": "running", "title": "zsh"]
        let resource = CmuxTuiSnapshotParser.terminal(fromSnapshotEntry: entry, machine: Self.machine)
        #expect(resource?.exit == nil)
        #expect(resource?.isFailedExitedTerminal == false)
    }
}
