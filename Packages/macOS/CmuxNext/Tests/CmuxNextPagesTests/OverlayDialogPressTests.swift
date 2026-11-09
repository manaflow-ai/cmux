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

    /// Review 33 of #37296 (F2): an edit the page sent before it had automation's value reached the host
    /// after it, and put the person's older text back over the value. An edit or press made against older
    /// values (an older `serial`) leaves the host's values as they are.
    @Test func anEditMadeBeforeAnAutomationValueDoesNotUndoIt() async throws {
        let spec = CmuxDialogSpec(title: "Rename", fields: [.text("name")],
                                  buttons: [.cancel(), CmuxDialogButton(id: "save", title: "Save", role: .default)])
        let dialog = CmuxDialogPresentation(id: 9, spec: spec, activeLook: nil)
        let provider = OverlayDialogProvider()
        dialog.renderer = provider
        provider.show(dialog)
        let context = PageCallContext(page: "cmux.overlay")
        _ = try await provider.call("cmux.overlay.dialog.edit", params: ["id": 9, "serial": 0, "values": ["name": "typed"]],
                                    context: context)
        #expect(dialog.values["name"] == .text("typed"))
        // Automation sets the field (values serial 1); the page's next edit, typed before it saw that, lands late.
        dialog.setValue(.text("set"), for: "name")
        _ = try await provider.call("cmux.overlay.dialog.edit", params: ["id": 9, "serial": 0, "values": ["name": "typed!"]],
                                    context: context)
        #expect(dialog.values["name"] == .text("set"))
        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        _ = try await provider.call("cmux.overlay.dialog.press",
                                    params: ["id": 9, "serial": 0, "button": "save", "values": ["name": "typed!"]], context: context)
        #expect(pressed == ["save"])
        #expect(dialog.values["name"] == .text("set"))
        // Once the page has the value, its edits count again.
        _ = try await provider.call("cmux.overlay.dialog.edit", params: ["id": 9, "serial": 1, "values": ["name": "set2"]],
                                    context: context)
        #expect(dialog.values["name"] == .text("set2"))
        withExtendedLifetime(dialog) {}
    }
}
