import Testing

@testable import CmuxCommandPalette

@Suite("CommandPaletteStaticShortcutHint")
struct CommandPaletteStaticShortcutHintTests {
    @Test("known commands resolve their built-in glyph")
    func knownCommands() {
        #expect(CommandPaletteStaticShortcutHint(commandId: "palette.closeTab").value == "⌘W")
        #expect(CommandPaletteStaticShortcutHint(commandId: "palette.closeWorkspace").value == "⌘⇧W")
        #expect(CommandPaletteStaticShortcutHint(commandId: "palette.openSettings").value == "⌘,")
        #expect(CommandPaletteStaticShortcutHint(commandId: "palette.terminalFindPrevious").value == "⌥⌘G")
        #expect(CommandPaletteStaticShortcutHint(commandId: "palette.terminalHideFind").value == "⌥⌘⇧F")
    }

    @Test("toggleFullScreen uses control+command glyph sequence")
    func toggleFullScreen() {
        #expect(
            CommandPaletteStaticShortcutHint(commandId: "palette.toggleFullScreen").value
                == "\u{2303}\u{2318}F"
        )
    }

    @Test("zoom commands share glyphs across browser and markdown")
    func zoomCommands() {
        #expect(CommandPaletteStaticShortcutHint(commandId: "palette.browserZoomIn").value == "⌘=")
        #expect(CommandPaletteStaticShortcutHint(commandId: "palette.markdownZoomIn").value == "⌘=")
        #expect(CommandPaletteStaticShortcutHint(commandId: "palette.browserZoomReset").value == "⌘0")
        #expect(CommandPaletteStaticShortcutHint(commandId: "palette.markdownZoomReset").value == "⌘0")
    }

    @Test("unknown command has no built-in hint")
    func unknownCommand() {
        #expect(CommandPaletteStaticShortcutHint(commandId: "palette.newWorkspace").value == nil)
        #expect(CommandPaletteStaticShortcutHint(commandId: "").value == nil)
    }
}
