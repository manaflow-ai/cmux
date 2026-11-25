import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// With the command palette open, a navigation chord the palette has no use for runs its action: Ctrl-` (New
/// Terminal Tab) makes a terminal, and the palette closes so the terminal gets the keyboard.
///
/// P0 2026-10-31 (Lawrence on v2.2.10-opt: "Ctrl-` does not work"). A real Ctrl-` (CuaDriver HID key) with the palette
/// open ran no action: journey ctrlbt-real-palette failed 1 of 1 on v2.2.10-opt 2efedfc3, v2.2.12-opt 152ca95f and the
/// feat tip 94089b6c969 (job 64148b99); the app's action log was empty after the key, and the key went into the
/// palette's search field. The key router decides keys only for a main window's content, and New Terminal Tab has no
/// main-menu item; the palette's key handler dropped every chord it did not map.
@MainActor
@Suite(.closesItsWindows)
struct PaletteNavigationChordTests {
    /// The actions the registry ran, in order.
    @MainActor final class Ran { var ids: [String] = [] }

    private static func palette() -> (PaletteController, Ran) {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let ran = Ran()
        for id: ActionID in ["newSurface", "toggleChecklistItemComplete", "closeTab", "newTab.default"] {
            registry.bind(id) { ran.ids.append(id.rawValue) }
        }
        let palette = PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
        palette.bindRegistryActions()
        return (palette, ran)
    }

    private static func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: keyCode))
    }

    @Test func ctrlBacktickWithThePaletteOpenRunsNewTerminalTabAndClosesThePalette() throws {
        let (palette, ran) = Self.palette()
        defer { palette.closeForTest() }
        palette.show(.commands)
        let panel = try #require(palette.visiblePanel)
        #expect(palette.handleKeyDown(try Self.key("`", keyCode: 50, modifiers: [.control]), in: panel),
                "the palette's field must not swallow Ctrl-`")
        #expect(ran.ids == ["newSurface"])
        #expect(!palette.isVisible, "the palette closes, so the new terminal gets the keyboard")
    }

    /// Typing stays the search field's, and a system chord (Cmd-W: Close Tab, the menu's and the palette's own rule)
    /// is not run from here; the palette stays open.
    @Test func typingAndSystemChordsDoNotRunFromThePalette() throws {
        let (palette, ran) = Self.palette()
        defer { palette.closeForTest() }
        palette.show(.commands)
        #expect(!palette.runsNavigationChord(try Self.key("`", keyCode: 50, modifiers: [])))
        #expect(!palette.runsNavigationChord(try Self.key("w", keyCode: 13, modifiers: [.command])))
        #expect(ran.ids.isEmpty)
        #expect(palette.isVisible)
    }

    /// A chord bound to an action that yields to a text field (`KeyBindingDefaults.notTextInput`: Cmd-Return's
    /// checklist toggle) does not run from the palette's field.
    @Test func aChordThatYieldsToTextInputDoesNotRun() throws {
        let (palette, ran) = Self.palette()
        defer { palette.closeForTest() }
        palette.show(.commands)
        #expect(!palette.runsNavigationChord(try Self.key("\r", keyCode: 36, modifiers: [.command])))
        #expect(!ran.ids.contains("toggleChecklistItemComplete"))
    }
}
