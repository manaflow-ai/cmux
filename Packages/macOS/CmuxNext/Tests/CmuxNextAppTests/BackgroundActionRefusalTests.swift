import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import Testing

/// A typed refusal (``ActionFailure``) from an action's background work keeps its own code on the
/// control socket, as the same refusal thrown at once does: `unavailable` with the reason, or
/// `not_found`. Only a daemon failure is a `daemon_error`.
@MainActor @Suite(.timeLimit(.minutes(1))) struct BackgroundActionRefusalTests {
    /// Runs an ad hoc action whose tracked work fails with `failure`, the way a handler's
    /// background task reports a thrown error (``ActionWorkFailure/init(_:_:)``).
    /// Returns the run's error, nil when it reported success.
    func run(failing failure: ActionFailure) async -> ControlError? {
        let registry = ActionRegistry()
        registry.register(Action(id: "test.backgroundRefusal", title: "Background") {
            registry.track(Task { @MainActor in
                do { throw failure } catch { return ActionWorkFailure("open", error) }
            })
        })
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: ControlIdentity(version: "1", build: "1", bundleID: nil, tag: "test", processID: 1),
                                   executor: bridge)
        bridge.attach(to: router)
        let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "test.backgroundRefusal", "wait": true,
        ]))
        guard case .failure(let error) = result else { return nil }
        return error
    }

    @Test func aRefusalFromBackgroundWorkIsUnavailableWithItsReason() async {
        guard let error = await run(failing: ActionFailure(message: "the window must have focus")) else {
            Issue.record("a refused run reported success")
            return
        }
        #expect(error.code == "unavailable")
        #expect(error.message.contains("the window must have focus"))
        #expect(error.data?["reason"] == "the window must have focus")
        #expect(error.data?["action"] == "test.backgroundRefusal")
    }

    @Test func aNotFoundFromBackgroundWorkIsNotFound() async {
        guard let error = await run(failing: .notFound("no such folder")) else {
            Issue.record("a refused run reported success")
            return
        }
        #expect(error.code == "not_found")
        #expect(error.message == "no such folder")
    }
}
