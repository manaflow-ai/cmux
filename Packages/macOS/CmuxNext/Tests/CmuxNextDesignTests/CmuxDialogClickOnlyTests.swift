import AppKit
@testable import CmuxNextDesign
import Testing

/// cmux issue 26412, fourth review: the Credential Vault's approval sheet opens on its own (a
/// socket call), and its Allow could be pressed by a key typed for the terminal: Space on a
/// focused button, or Tab then Space. A click-only button takes no key and never the keyboard,
/// and no click in its first half second on screen; a dialog that does not focus its field
/// leaves typing out of it.
@MainActor
struct CmuxDialogClickOnlyTests {
    nonisolated static let approval = CmuxDialogSpec(title: "Allow a command to use PROD_DB?", buttons: [
        .cancel(), CmuxDialogButton(id: "allow", title: "Allow", role: .default, key: "a", clickOnly: true),
    ])
    nonisolated static let entry = CmuxDialogSpec(title: "Add GH_TOKEN", fields: [
        .text(id: "value", label: nil, initial: "", placeholder: nil, secure: true),
    ], buttons: [.cancel(), CmuxDialogButton(id: "save", title: "Save", clickOnly: true)], focusesField: false)

    @Test func noKeyPressesAClickOnlyButtonOrShowsOnIt() {
        let spec = Self.approval
        for (key, modifiers) in [(CmuxDialogKeys.Key.return, CmuxDialogKeys.Modifiers()), (.return, .command), (.character("a"), .command)] {
            #expect(CmuxDialogKeys.action(for: key, modifiers: modifiers, in: spec) == nil, "\(key) \(modifiers)")
        }
        #expect(CmuxDialogKeys.hint(for: spec.buttons[1], in: spec) == nil)
        #expect(CmuxDialogKeys.action(for: .escape, modifiers: [], in: spec) == .press("cancel"), "Escape still cancels")
    }

    @Test func aClickOnlyButtonNeverHasTheKeyboard() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let dialog = CmuxDialogView(spec: Self.approval)
        try #require(window.contentView).addSubview(dialog)
        let allow = try #require(dialog.buttonViews.first { $0.button.id == "allow" })
        #expect(!allow.acceptsFirstResponder && !allow.canBecomeKeyView)
        #expect(!dialog.focusables.contains(allow), "Tab never reaches it")
        dialog.focusInitial()
        #expect(window.firstResponder === dialog.buttonViews.first { $0.button.id == "cancel" }, "the keyboard starts on Cancel")

        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        allow.keyDown(with: space)
        #expect(!pressed.contains("allow"), "Space does not press it (the key goes on to the dialog, whose keyboard is on Cancel)")

        let shown = try #require(allow.shownAt, "armed from when it came on screen")
        #expect(!allow.takesClick(at: shown + 0.1), "a click aimed at what was there before does not land")
        #expect(allow.takesClick(at: shown + CmuxDialogButtonView.armDelay + 0.1))
        #expect(!allow.acceptsFirstMouse(for: nil), "a click that only brings the window forward does not press it")
        #expect(try #require(dialog.buttonViews.first { $0.button.id == "cancel" }).takesClick(at: shown), "other buttons are unchanged")
    }

    @Test func aDialogThatDoesNotFocusItsFieldStartsOnCancel() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let dialog = CmuxDialogView(spec: Self.entry)
        try #require(window.contentView).addSubview(dialog)
        dialog.focusInitial()
        #expect(!(window.firstResponder is NSTextView), "typing does not land in the value field")
        #expect(window.firstResponder === dialog.buttonViews.first { $0.button.id == "cancel" })
        #expect(dialog.handle(.return, modifiers: []) == false, "Return saves nothing")
    }
}
