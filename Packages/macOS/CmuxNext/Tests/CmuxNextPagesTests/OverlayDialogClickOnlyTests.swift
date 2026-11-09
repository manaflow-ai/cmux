import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
import Foundation
import Testing

/// cmux issue 26412: the Credential Vault's approval sheet opens on its own (a socket call), and its Allow
/// releases a secret. Drawn by the overlay page's React card since #37296, a click-only button still takes no
/// key, tells the page to give it no focus, and takes no press until its card has been on screen for
/// ``CmuxDialogClickOnlyArm/delay`` (the dialog pool takes no first mouse); a dialog that does not focus its field says so to the page.
@MainActor
struct OverlayDialogClickOnlyTests {
    nonisolated static let approval = CmuxDialogSpec(title: "Allow a command to use PROD_DB?", buttons: [
        .cancel(), CmuxDialogButton(id: "allow", title: "Allow", role: .default, key: "a", clickOnly: true),
    ])
    nonisolated static let entry = CmuxDialogSpec(title: "Add GH_TOKEN", fields: [
        .text(id: "value", label: nil, initial: "", placeholder: nil, secure: true),
    ], buttons: [.cancel(), CmuxDialogButton(id: "save", title: "Save", clickOnly: true)], focusesField: false)

    let context = PageCallContext(page: "cmux.overlay")

    @Test func noKeyPressesAClickOnlyButtonOrShowsOnIt() {
        let spec = Self.approval
        for (key, modifiers) in [(CmuxDialogKeys.Key.return, CmuxDialogKeys.Modifiers()), (.return, .command), (.character("a"), .command)] {
            #expect(CmuxDialogKeys.action(for: key, modifiers: modifiers, in: spec) == nil, "\(key) \(modifiers)")
        }
        #expect(CmuxDialogKeys.hint(for: spec.buttons[1], in: spec) == nil)
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: spec) == .press("cancel"), "Escape still cancels")
        // The page answers keys with exactly the host's map: Allow is in none of it.
        let keys = OverlayDialogProvider.keys(spec)
        #expect(keys["return"] == nil || keys["return"] == .null)
        #expect(keys["command"]?["a"] == nil)
    }

    @Test func thePageLearnsWhichButtonsAreClickOnlyAndWhetherTheFieldTakesTheKeyboard() throws {
        let approval = OverlayDialogProvider.wire(CmuxDialogPresentation(id: 1, spec: Self.approval, activeLook: nil), focus: .null)
        let buttons = try #require(approval["buttons"]?.arrayValue)
        #expect(buttons.first { $0["id"] == "allow" }?["clickOnly"] == .bool(true))
        #expect(buttons.first { $0["id"] == "cancel" }?["clickOnly"] == nil)
        #expect(approval["focusesField"] == nil, "a dialog that focuses its field says nothing")
        let entry = OverlayDialogProvider.wire(CmuxDialogPresentation(id: 2, spec: Self.entry, activeLook: nil), focus: .null)
        #expect(entry["focusesField"] == .bool(false))
    }

    @Test func aClickOnlyPressWaitsForTheCardToBeOnScreen() async throws {
        let dialog = CmuxDialogPresentation(id: 3, spec: Self.approval, activeLook: nil)
        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        let provider = OverlayDialogProvider()
        var clock: TimeInterval = 100
        provider.now = { clock }
        provider.show(dialog)

        _ = try await press(provider, 3, "allow")
        #expect(pressed.isEmpty, "not drawn yet: a click aimed at what was there before")
        _ = try await provider.call("cmux.overlay.dialog.painted", params: ["id": 3], context: context)
        clock += 0.1
        _ = try await press(provider, 3, "allow")
        #expect(pressed.isEmpty, "within the arm delay of the card painting")
        _ = try await press(provider, 3, "cancel")
        #expect(pressed == ["cancel"], "other buttons are unchanged")

        clock += CmuxDialogClickOnlyArm.delay
        _ = try await press(provider, 3, "allow")
        #expect(pressed == ["cancel", "allow"])
        withExtendedLifetime(dialog) {}
    }

    @Test func showingAgainArmsItAgain() async throws {
        let dialog = CmuxDialogPresentation(id: 4, spec: Self.approval, activeLook: nil)
        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        let provider = OverlayDialogProvider()
        var clock: TimeInterval = 100
        provider.now = { clock }
        provider.show(dialog)
        provider.resetFocus(dialog)
        _ = try await provider.call("cmux.overlay.dialog.painted", params: ["id": 4], context: context)
        clock += 5

        // A tab switch shows it again: its Allow waits again.
        provider.resetFocus(dialog)
        _ = try await press(provider, 4, "allow")
        #expect(pressed.isEmpty)
        clock += CmuxDialogClickOnlyArm.delay
        _ = try await press(provider, 4, "allow")
        #expect(pressed == ["allow"])
        withExtendedLifetime(dialog) {}
    }

    @Test func theArmTakesNoPressBeforeItsDelay() {
        var arm = CmuxDialogClickOnlyArm()
        #expect(!arm.takes(at: 1_000), "never drawn")
        arm.rearm(at: 10)
        #expect(!arm.takes(at: 10.4))
        #expect(arm.takes(at: 10.5))
        arm.rearm(at: 20)
        #expect(!arm.takes(at: 20.1), "shown again")
    }

    private func press(_ provider: OverlayDialogProvider, _ id: Int, _ button: String) async throws -> JSONValue {
        try await provider.call("cmux.overlay.dialog.press", params: ["id": .number(Double(id)), "button": .string(button)], context: context)
    }
}
