@testable import CmuxNextApp
import Testing

/// The helper gate is the server menu bar item's, not a process global: one app's Fix and Stop
/// Serving take turns on their owner's gate, and another owner (another app, a test) holds its own.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ServerFixGateOwnerTests {
    @Test func twoOwnersHoldTwoGates() async {
        let first = ServerMenuBarController(), second = ServerMenuBarController()
        #expect(first.fixGate !== second.fixGate)
        await first.fixGate.acquire()
        // With one shared gate this acquire would wait for the first owner's release, which never comes.
        await second.fixGate.acquire()
        second.fixGate.release()
        first.fixGate.release()
    }

    @Test func aFixAndStopServingOfOneOwnerShareItsGate() {
        let owner = ServerMenuBarController()
        #expect(ServerHealthFixer.helper(gate: owner.fixGate).gate === owner.fixGate)
        #expect(ServerStopServing.app(gate: owner.fixGate).gate === owner.fixGate)
    }
}
