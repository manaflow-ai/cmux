import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Answers every action with work that finishes after `delay`.
private final class SlowWorkExecutor: ControlActionExecutor {
    let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }

    @MainActor func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        let delay = delay
        return ControlActionRun(outcome: .ran, work: [Task {
            try? await Task.sleep(for: delay)
            return nil
        }])
    }
}

/// A request that starts a terminal waits for cmux-tui to launch its host,
/// which can take longer than the 2 s control-plane deadline under load.
/// Such a request uses the terminal start deadline end to end.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct TerminalStartDeadlineTests {
    static func router(executor: any ControlActionExecutor) -> ControlRouter {
        let registry = ActionRegistry.standard()
        registry.context = RegistryReachabilityTests.fullContext
        let router = ControlRouter(identity: testIdentity(), executor: executor,
                                   configuration: .init(requestDeadline: .milliseconds(100)))
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        return router
    }

    static func run(_ router: ControlRouter, _ action: String, target: String) async -> Result<JSONValue, ControlError> {
        await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": .string(action), "target": .string(target), "wait": true,
        ]))
    }

    /// Regression: `action.run tab new-terminal --wait` gave up at the 2 s
    /// control-plane deadline while cmux-tui was still starting the host.
    @Test func waitedTerminalCreateOutlastsTheControlPlaneDeadline() async throws {
        let router = Self.router(executor: SlowWorkExecutor(delay: .milliseconds(400)))
        let result = await Self.run(router, "newSurface", target: "tab:t1")
        guard case .success(let value) = result else {
            Issue.record("new-terminal timed out at the control-plane deadline: \(result)")
            return
        }
        #expect(value["waited"] == true)
    }

    @Test func waitedNonCreatingActionKeepsTheControlPlaneDeadline() async throws {
        let router = Self.router(executor: SlowWorkExecutor(delay: .milliseconds(400)))
        let result = await Self.run(router, "closeTab", target: "tab:t1")
        guard case .failure(let error) = result else {
            Issue.record("close-tab ignored the control-plane deadline")
            return
        }
        #expect(error.code == "timeout")
        #expect(error.data?["terminal_may_appear"] == nil)
    }
}
