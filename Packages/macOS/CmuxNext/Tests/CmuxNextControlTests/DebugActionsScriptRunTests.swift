import CmuxNextActions
@testable import CmuxNextControl
import Testing

/// Internal Developer Mode decides what the person is offered, not what a script may run: a socket
/// `action.run` of a debug-only action works with the toggle off wherever developer tools exist, and
/// never in a Release build.
@MainActor
@Suite struct DebugActionsScriptRunTests {
    private static func run(devTools: Bool, on: Bool) -> (ControlActionOutcome, Bool) {
        let registry = ActionRegistry.standard()
        var ran = false
        registry.bindEffect("openDebugSettings") { _ in
            ran = true
            return .done
        }
        registry.debugActions = DebugActionGate(devTools: devTools, isOn: { on })
        let outcome = RegistryControlBridge(registry: registry).performAction(ControlActionRequest(actionID: "openDebugSettings"))
        return (outcome, ran)
    }

    @Test func aSocketRunWorksWithTheToggleOff() {
        let (outcome, ran) = Self.run(devTools: true, on: false)
        #expect(outcome == .ran)
        #expect(ran)
    }

    @Test func aReleaseBuildRefusesTheSocketRun() {
        let (outcome, ran) = Self.run(devTools: false, on: true)
        #expect(outcome == .unavailable)
        #expect(!ran)
    }
}
