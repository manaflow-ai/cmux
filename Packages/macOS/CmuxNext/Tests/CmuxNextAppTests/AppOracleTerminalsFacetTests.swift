#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextOracle
import Testing

/// The app's `terminals` facet (p15-oracle-044): AppServices lists it as a background facet, so its screens are read
/// off the main actor, and a view's attach machine phase maps to the schema's attach states.
/// Run: `swift test --filter AppOracleTerminalsFacetTests`.
@MainActor @Suite(.serialized) struct AppOracleTerminalsFacetTests {
    @Test func theAttachMachinePhasesMapToTheSchemaStates() {
        typealias Machine = TerminalAttachMachine<Int>
        let pending = Machine.Pending(attempt: 1, failures: 0, size: CellSize(cols: 80, rows: 24), link: nil)
        #expect(Machine.Phase.live(1).oracleAttach == .attached)
        #expect(Machine.Phase.attaching(pending).oracleAttach == .attaching)
        #expect(Machine.Phase.reattaching(pending).oracleAttach == .attaching)
        #expect(Machine.Phase.detached.oracleAttach == .detached)
        #expect(Machine.Phase.closed.oracleAttach == .detached)
        #expect(Machine.Phase.exited.oracleAttach == .dead)
    }

    @Test func theAppListsTheFacetOffTheMainActor() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let facets = services.makeOracleFacets()
        #expect(facets.provided.contains(.terminals))
        let capture = try facets.beginCapture([.terminals])
        #expect(capture.completed == nil)
        // No machine has a terminal yet.
        let snapshot = try await capture.finish()
        #expect(snapshot["terminals"] == ["list": .array([])] as OracleValue)
    }
}
#endif
