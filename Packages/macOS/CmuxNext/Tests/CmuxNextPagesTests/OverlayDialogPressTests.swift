@testable import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Reviews 21 and 25 of #37296: a consent prompt must not be answered by a page probe, and VoiceOver's
/// press (an accessibility action, with no key or mouse event on the page) must still answer every dialog.
/// A dialog's page refuses page probes from the turn it is made (PageRegistryProbeTests), so a press that
/// reaches its provider is the person's, however they pressed.
@MainActor
struct OverlayDialogPressTests {
    @Test func aPressWithNoKeyOrMouseEventAnswersTheDialog() async throws {
        let spec = CmuxDialogSpec(title: "Close Workspace?", buttons: [.cancel(), CmuxDialogButton(id: "close", title: "Close", role: .default)])
        let dialog = CmuxDialogPresentation(id: 7, spec: spec, activeLook: nil)
        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        let provider = OverlayDialogProvider()
        provider.show(dialog)
        // An accessibility press: no gesture on the page.
        _ = try await provider.call("cmux.overlay.dialog.press", params: ["id": 7, "button": "cancel"],
                                    context: PageCallContext(page: "cmux.overlay"))
        #expect(pressed == ["cancel"])
        withExtendedLifetime(dialog) {}
    }
}
