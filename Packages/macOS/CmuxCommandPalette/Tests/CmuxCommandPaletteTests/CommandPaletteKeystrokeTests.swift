import AppKit
import Testing

@testable import CmuxCommandPalette

@Suite("CommandPaletteKeystroke routing")
struct CommandPaletteKeystrokeTests {
    @Test("Does not consume any shortcut while the palette is hidden")
    func doesNotConsumeWhileHidden() {
        let keystroke = CommandPaletteKeystroke(keyCode: 45, modifierFlags: [.command], characters: "n")
        #expect(keystroke.shouldConsumeWhilePaletteVisible(isPaletteVisible: false) == false)
    }

    @Test("Consumes app command shortcuts while the palette is visible")
    func consumesAppCommandShortcuts() {
        #expect(
            CommandPaletteKeystroke(keyCode: 45, modifierFlags: [.command], characters: "n")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
        #expect(
            CommandPaletteKeystroke(keyCode: 17, modifierFlags: [.command], characters: "t")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
        #expect(
            CommandPaletteKeystroke(keyCode: 43, modifierFlags: [.command, .shift], characters: ",")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
    }

    @Test("Allows clipboard/undo and arrow/delete editing while the palette is visible")
    func allowsEditingShortcuts() {
        for keystroke in [
            CommandPaletteKeystroke(keyCode: 9, modifierFlags: [.command], characters: "v"),
            CommandPaletteKeystroke(keyCode: 6, modifierFlags: [.command], characters: "z"),
            CommandPaletteKeystroke(keyCode: 6, modifierFlags: [.command, .shift], characters: "z"),
            CommandPaletteKeystroke(keyCode: 123, modifierFlags: [.command], characters: ""),
            CommandPaletteKeystroke(keyCode: 51, modifierFlags: [.command], characters: ""),
        ] {
            #expect(keystroke.shouldConsumeWhilePaletteVisible(isPaletteVisible: true) == false)
        }
    }

    @Test("Consumes Escape while the palette is visible")
    func consumesEscape() {
        #expect(
            CommandPaletteKeystroke(keyCode: 53, modifierFlags: [], characters: "")
                .shouldConsumeWhilePaletteVisible(isPaletteVisible: true)
        )
    }

    @Test("Return and keypad Enter submit with no modifiers in every mode")
    func submitsOnPlainReturn() {
        #expect(
            CommandPaletteKeystroke(keyCode: 36, modifierFlags: [], characters: "\r")
                .shouldSubmitWithReturn(mode: "single_line")
        )
        #expect(
            CommandPaletteKeystroke(keyCode: 76, modifierFlags: [], characters: "\r")
                .shouldSubmitWithReturn(mode: "workspace_description_input")
        )
    }

    @Test("Shift+Return submits except in the workspace-description mode")
    func shiftReturnDependsOnMode() {
        #expect(
            CommandPaletteKeystroke(keyCode: 36, modifierFlags: [.shift], characters: "\r")
                .shouldSubmitWithReturn(mode: "single_line")
        )
        #expect(
            CommandPaletteKeystroke(keyCode: 36, modifierFlags: [.shift], characters: "\r")
                .shouldSubmitWithReturn(mode: "workspace_description_input") == false
        )
    }

    @Test("Non-Return keys never submit")
    func nonReturnDoesNotSubmit() {
        #expect(
            CommandPaletteKeystroke(keyCode: 45, modifierFlags: [], characters: "n")
                .shouldSubmitWithReturn(mode: "single_line") == false
        )
    }
}

@Suite("CommandPaletteSelectionNavigation routing")
struct CommandPaletteSelectionNavigationTests {
    @Test("Routes an interactive non-inline delta")
    func routesInteractiveDelta() {
        #expect(
            CommandPaletteSelectionNavigation(delta: -1, isInteractive: true, usesInlineTextHandling: false)
                .shouldRoute
        )
    }

    @Test("Does not route when inline text handling is active")
    func blockedByInlineTextHandling() {
        #expect(
            CommandPaletteSelectionNavigation(delta: -1, isInteractive: true, usesInlineTextHandling: true)
                .shouldRoute == false
        )
    }

    @Test("Does not route a nil delta or a non-interactive palette")
    func blockedByMissingDeltaOrInactive() {
        #expect(
            CommandPaletteSelectionNavigation(delta: nil, isInteractive: true, usesInlineTextHandling: false)
                .shouldRoute == false
        )
        #expect(
            CommandPaletteSelectionNavigation(delta: 1, isInteractive: false, usesInlineTextHandling: false)
                .shouldRoute == false
        )
    }
}
