import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextSettings
import Testing

/// openDiffViewer's background path (a pane folder with no repository, a run without focus)
/// refuses through its tracked work. That refusal must keep its code on the socket, as the direct
/// palette.openDirectoryDiffViewer refusal does: `unavailable` with the reason, never
/// `daemon_error` (the trunk's typed background refusals, 0ed5a1c46b9).
@MainActor @Suite(.timeLimit(.minutes(1))) struct PickerRefusalCodeTests {
    @Test func theBackgroundPickerRefusalIsUnavailableWithItsReason() async throws {
        let registry = ActionRegistry()
        registry.register(Action(id: "test.backgroundPicker", title: "Background picker") {
            registry.track(Task { @MainActor in ViewerHandlers.backgroundPickerRefusal() })
        })
        let bridge = RegistryControlBridge(registry: registry)
        let router = ControlRouter(identity: ControlIdentity(version: "1", build: "1", bundleID: nil, tag: "test", processID: 1),
                                   executor: bridge)
        bridge.attach(to: router)
        let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
            "action": "test.backgroundPicker", "wait": true,
        ]))
        guard case .failure(let error) = result else { Issue.record("a refused run reported success"); return }
        #expect(error.code == "unavailable")
        #expect(error.data?["reason"] == .string(MiscHandlerStrings.pickerNeedsFocus))
    }
}
