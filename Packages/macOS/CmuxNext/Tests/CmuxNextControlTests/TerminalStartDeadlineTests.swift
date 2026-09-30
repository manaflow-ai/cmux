import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Answers every action with work that finishes after `delay`, failing
/// with `failure` when one is set.
private final class SlowWorkExecutor: ControlActionExecutor {
    let delay: Duration
    let failure: ActionWorkFailure?

    init(delay: Duration, failure: ActionWorkFailure? = nil) {
        self.delay = delay
        self.failure = failure
    }

    @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }

    @MainActor func performActionTracked(_ request: ControlActionRequest) -> ControlActionRun {
        let delay = delay
        let failure = failure
        return ControlActionRun(outcome: .ran, work: [Task {
            try? await Task.sleep(for: delay)
            return failure
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

    /// A create that outlives even the terminal start deadline answers a
    /// timeout that tells the caller the terminal may still appear.
    @Test func terminalCreatePastItsDeadlineSaysTheTerminalMayAppear() async throws {
        let registry = ActionRegistry.standard()
        registry.context = RegistryReachabilityTests.fullContext
        // The work outlives the test: only the deadline can answer.
        let router = ControlRouter(identity: testIdentity(), executor: SlowWorkExecutor(delay: .seconds(30)),
                                   configuration: .init(requestDeadline: .milliseconds(50), terminalStartDeadline: .milliseconds(150)))
        router.updateCatalog(RegistryControlBridge.catalog(from: registry))
        let result = await Self.run(router, "newSurface", target: "tab:t1")
        guard case .failure(let error) = result else {
            Issue.record("expected a timeout")
            return
        }
        #expect(error.code == "timeout")
        #expect(error.data?["terminal_may_appear"] == true)
        #expect(error.message.contains("may still appear"))
    }

    /// The daemon command's own terminal start timeout reaches the caller
    /// as the same typed timeout.
    @Test func daemonTerminalStartTimeoutIsATypedTimeout() async throws {
        let failure = ActionWorkFailure("new-tab: timed out", terminalMayAppear: true)
        let router = Self.router(executor: SlowWorkExecutor(delay: .zero, failure: failure))
        let result = await Self.run(router, "newSurface", target: "tab:t1")
        guard case .failure(let error) = result else {
            Issue.record("expected a timeout")
            return
        }
        #expect(error.code == "timeout")
        #expect(error.data?["terminal_may_appear"] == true)
        #expect(error.data?["action"] == "newSurface")
    }

    @Test func compatCreationVerbsUseTheTerminalStartDeadline() {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        let service = CompatService(frontend: HeadlessCompatFrontend()) { nil }
        service.install(on: router)
        let snapshot = router.snapshots.current
        for name in ["surface.create", "surface.split", "pane.create", "workspace.create"] {
            let method = router.method(named: name)
            #expect(method != nil, "\(name)")
            let terminal = ControlRequest(id: "1", method: name, params: ["type": "terminal"])
            let browser = ControlRequest(id: "1", method: name, params: ["type": "browser"])
            #expect(method?.startsTerminal(terminal, snapshot) == true, "\(name)")
            #expect(method?.startsTerminal(browser, snapshot) == false, "\(name)")
        }
        #expect(router.method(named: "surface.list")?.startsTerminal(ControlRequest(id: "1", method: "surface.list", params: [:]), snapshot) == false)
        withExtendedLifetime(service) {}
    }
}
