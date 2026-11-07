@testable import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// Review 21 of #37296: the overlay page took a dialog's press from any caller, so `debug.page`'s call
/// (or page script) could press "allow" on a consent prompt that `debug.dialog` keeps to the person. A
/// press or an edit from the page now needs the person's own key or mouse event, and one event answers
/// one press.
@MainActor
struct OverlayDialogPersonOnlyTests {
    private static func shown() -> (OverlayDialogProvider, CmuxDialogPresentation, () -> [String]) {
        let spec = CmuxDialogSpec(title: "Allow clipboard access?", fields: [
            .text(id: "note", label: nil, initial: "", placeholder: nil, secure: false)],
            buttons: [.cancel(), CmuxDialogButton(id: "allow", title: "Allow", role: .default)])
        let dialog = CmuxDialogPresentation(id: 7, spec: spec, activeLook: nil)
        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        let provider = OverlayDialogProvider()
        provider.show(dialog)
        return (provider, dialog, { pressed })
    }

    private static func press(_ provider: OverlayDialogProvider, _ context: PageCallContext) async -> Bool {
        do {
            _ = try await provider.call("cmux.overlay.dialog.press", params: ["id": 7, "button": "allow"], context: context)
            return true
        } catch {
            return false
        }
    }

    @Test func aPressWithoutThePersonsEventAnswersNothing() async {
        let (provider, _, pressed) = Self.shown()
        #expect(await !Self.press(provider, PageCallContext(page: "cmux.overlay")))
        #expect(pressed().isEmpty)
    }

    @Test func thePersonsEventAnswersOnePress() async {
        let (provider, _, pressed) = Self.shown()
        let click = PageCallContext(page: "cmux.overlay", userGesture: true, gestureEvent: 41)
        #expect(await Self.press(provider, click))
        #expect(pressed() == ["allow"])
        #expect(await !Self.press(provider, click))
        #expect(pressed() == ["allow"])
    }

    @Test func anEditWithoutThePersonsEventChangesNoValue() async {
        let (provider, dialog, _) = Self.shown()
        let edit: JSONValue = ["id": 7, "values": ["note": "from a script"]]
        await #expect(throws: PageError.self) {
            _ = try await provider.call("cmux.overlay.dialog.edit", params: edit, context: PageCallContext(page: "cmux.overlay"))
        }
        #expect(dialog.values["note"] == .text(""))
    }
}
