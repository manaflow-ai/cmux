import AppKit
@testable import CmuxNextDesign
import Testing

/// u2647: the settings approval sheet ("Change browser.searchEngine?") showed Cancel and
/// Change with no sign that Escape and Return press them. Every cmux dialog button now
/// shows the key that presses it, and that key really presses it.
@MainActor @Suite struct DialogKeyHintTests {
    /// The approval sheet's spec (`DestructiveConfirmation.spec`): Cancel, then the default.
    nonisolated static let approval = CmuxDialogSpec(title: "Change browser.searchEngine?", lines: ["Set it to duckduckgo."],
                                         buttons: [.cancel(), CmuxDialogButton(id: "confirm", title: "Change", role: .default)])
    /// The quit sheet's shape: Don't Save with Command-D, Cancel, Save.
    nonisolated static let unsaved = CmuxDialogSpec(title: "Save changes?", buttons: [
        CmuxDialogButton(id: "discard", title: "Don't Save", role: .destructive, key: "d"),
        .cancel(),
        CmuxDialogButton(id: "save", title: "Save", role: .default),
    ])
    /// One plain button: Escape presses it (the spec's cancel button).
    nonisolated static let notice = CmuxDialogSpec(title: "Done", buttons: [CmuxDialogButton(id: "close", title: "Close")])
    /// One default button: Return and Escape both press it; Return is the one shown.
    nonisolated static let ok = CmuxDialogSpec(title: "Saved", buttons: [.ok()])

    @Test func theApprovalSheetShowsEscapeOnCancelAndReturnOnChange() {
        let spec = Self.approval
        #expect(CmuxDialogKeys.hint(for: spec.buttons[0], in: spec) == .escape)
        #expect(CmuxDialogKeys.hint(for: spec.buttons[1], in: spec) == .return)
        #expect(CmuxDialogKeyHint.escape.glyph == "⎋")
        #expect(CmuxDialogKeyHint.return.glyph == "↩")
    }

    @Test func aCommandKeyButtonShowsItsChord() {
        let spec = Self.unsaved
        #expect(CmuxDialogKeys.hint(for: spec.buttons[0], in: spec) == .command("d"))
        #expect(CmuxDialogKeyHint.command("d").glyph == "⌘D")
        #expect(CmuxDialogKeys.hint(for: spec.buttons[1], in: spec) == .escape)
        #expect(CmuxDialogKeys.hint(for: spec.buttons[2], in: spec) == .return)
    }

    @Test func aLoneButtonShowsTheKeyThatPressesIt() {
        #expect(CmuxDialogKeys.hint(for: Self.notice.buttons[0], in: Self.notice) == .escape)
        #expect(CmuxDialogKeys.hint(for: Self.ok.buttons[0], in: Self.ok) == .return)
    }

    /// No button shows a key that does not press it, and every button a key presses shows one.
    @Test(arguments: [approval, unsaved, notice, ok])
    func everyShownKeyPressesItsButton(_ spec: CmuxDialogSpec) throws {
        for button in spec.buttons {
            let hint = try #require(CmuxDialogKeys.hint(for: button, in: spec), "\(button.title) shows no key")
            #expect(CmuxDialogKeys.action(for: hint.key, modifiers: hint.modifiers, in: spec) == .press(button.id),
                    "\(button.title) shows \(hint.glyph), which does not press it")
        }
    }

    /// The drawn dialog: each button's title carries its keycap, VoiceOver reads the key,
    /// and pressing the shown key answers that button.
    @Test(arguments: [approval, unsaved])
    func theDrawnDialogShowsAndAnswersEachKey(_ spec: CmuxDialogSpec) throws {
        let view = CmuxDialogView(spec: spec)
        #expect(view.buttonViews.count == spec.buttons.count)
        for buttonView in view.buttonViews {
            let hint = try #require(buttonView.keyHint, "\(buttonView.button.title) draws no key")
            #expect(buttonView.attributedTitle.string.contains(hint.glyph))
            #expect(buttonView.attributedTitle.string.hasPrefix(buttonView.button.title))
            #expect(buttonView.accessibilityLabel() == buttonView.button.title, "automation finds buttons by title")
            #expect(buttonView.accessibilityHelp()?.contains(hint.spokenName) == true)
            var pressed: String?
            view.onPress = { pressed = $0 }
            #expect(view.handle(hint.key, modifiers: hint.modifiers))
            #expect(pressed == buttonView.button.id)
        }
    }

    /// A retitled button ("Copy Link" turning into "Copied") keeps its keycap.
    @Test func aRetitledButtonKeepsItsKey() throws {
        let view = CmuxDialogButtonView(CmuxDialogButton(id: "copy", title: "Copy Link", role: .default), hint: .return,
                                        target: nil, action: NSSelectorFromString("noop:"))
        view.retitle("Copied")
        #expect(view.attributedTitle.string.hasPrefix("Copied"))
        #expect(view.attributedTitle.string.contains("↩"))
    }

    @Test func theSpokenKeysAreWords() {
        #expect(CmuxDialogKeyHint.return.spokenName == "Return")
        #expect(CmuxDialogKeyHint.escape.spokenName == "Escape")
        #expect(CmuxDialogKeyHint.command("d").spokenName == "Command-D")
    }
}
