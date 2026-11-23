import AppKit
@testable import CmuxNextDesign
import Testing

/// QA chrome-parity-v2-1 (multi-line paste confirm): the dialog opened with the keyboard on its
/// Deny button, so a person typing on ("seq 1 10") had the Space press Deny, and the paste was
/// lost. A dialog opening never puts the keyboard on a button the person did not choose: Space
/// presses nothing until Tab (or a click) moves to a button, while Return still presses the
/// default button and Escape the cancel one. The overlay page draws the card and its focus
/// (``CmuxDialogView``, DialogNativeCardTests); this guards the keys the dialog
/// itself answers (`CmuxDialogPresentation.handle`), which a missed key reaches.
@MainActor @Suite struct DialogInitialFocusTests {
    /// The paste confirm's shape: Deny (Escape), then Allow (Return).
    nonisolated static let paste = CmuxDialogSpec(title: "Paste into the terminal?", buttons: [
        CmuxDialogButton(id: "deny", title: "Deny", role: .cancel),
        CmuxDialogButton(id: "allow", title: "Allow", role: .default),
    ])
    /// A destructive default: Return closes, a typed Space must not.
    nonisolated static let close = CmuxDialogSpec(title: "Close the running terminal?", buttons: [
        .cancel(), CmuxDialogButton(id: "close", title: "Close", role: .default),
    ])
    /// No default at all: Escape is the only key.
    nonisolated static let noDefault = CmuxDialogSpec(title: "Allow a program to read the clipboard?", buttons: [
        CmuxDialogButton(id: "deny", title: "Deny", role: .cancel),
        CmuxDialogButton(id: "allow", title: "Allow"),
    ])

    /// Records the focus moves the dialog asks its drawing for.
    @MainActor private final class Drawing: CmuxDialogRendering {
        var moves: [Bool] = []
        func dialogValuesChanged(_ dialog: CmuxDialogPresentation) {}
        func dialogMoveFocus(_ dialog: CmuxDialogPresentation, backward: Bool) { moves.append(backward) }
    }

    private static func shown(_ spec: CmuxDialogSpec) -> (CmuxDialogPresentation, () -> [String]) {
        let dialog = CmuxDialogPresentation(id: 1, spec: spec, activeLook: nil)
        var pressed: [String] = []
        dialog.onPress = { pressed.append($0) }
        return (dialog, { pressed })
    }

    @Test(arguments: [paste, close, noDefault])
    func aTypedSpaceAsTheDialogOpensPressesNoButton(_ spec: CmuxDialogSpec) {
        let (dialog, pressed) = Self.shown(spec)
        for character in ["s", " ", "1"] as [Character] {
            #expect(!dialog.handle(.character(character), modifiers: []), "the dialog took a typed \(character)")
        }
        #expect(pressed().isEmpty, "typing on pressed \(pressed())")
    }

    @Test(arguments: [paste, close])
    func returnStillPressesTheDefaultButton(_ spec: CmuxDialogSpec) {
        let (dialog, pressed) = Self.shown(spec)
        #expect(dialog.handle(.return, modifiers: []))
        #expect(pressed() == [spec.defaultButton?.id].compactMap { $0 })
    }

    @Test(arguments: [paste, close, noDefault])
    func escapeStillPressesTheCancelButton(_ spec: CmuxDialogSpec) {
        let (dialog, pressed) = Self.shown(spec)
        #expect(dialog.handle(.escape, modifiers: []))
        #expect(pressed() == [spec.cancelButton?.id].compactMap { $0 })
    }

    /// Tab asks the drawing to move the keyboard (forward; Shift-Tab back) and presses nothing.
    @Test func tabMovesTheFocusAndPressesNothing() {
        let (dialog, pressed) = Self.shown(Self.paste)
        let drawing = Drawing()
        dialog.renderer = drawing
        #expect(dialog.handle(.tab, modifiers: []))
        #expect(dialog.handle(.tab, modifiers: .shift))
        #expect(drawing.moves == [false, true])
        #expect(pressed().isEmpty)
    }
}
