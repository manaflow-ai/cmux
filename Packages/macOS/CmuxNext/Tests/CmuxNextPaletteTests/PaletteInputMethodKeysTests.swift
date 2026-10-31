import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// An input method composing in the palette's query (Japanese, Chinese,
/// Korean marked text) owns Return, Escape and the arrows: Return commits
/// the composition instead of running the selected row, Down picks a
/// candidate instead of moving the selection, as in a content window
/// (`KeyRouter.belongsToInputMethod`).
@MainActor
@Suite(.closesItsWindows)
struct PaletteInputMethodKeysTests {
    private static func palette() -> PaletteController {
        _ = NSApplication.shared
        return PaletteController(registry: ActionRegistry.standard(), sources: PaletteSources(), frecencyPersistence: nil)
    }

    /// A window whose first responder is a text view with `marked` as marked text.
    private static func composingWindow(marked: String?) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        window.contentView = field
        try #require(window.makeFirstResponder(field))
        if let marked {
            field.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0),
                                replacementRange: NSRange(location: NSNotFound, length: 0))
            try #require(field.hasMarkedText())
        }
        return window
    }

    private static func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: characters,
                                                  charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        return event
    }

    @Test func returnEscapeAndArrowsReachAComposingInputMethod() throws {
        let palette = Self.palette()
        let window = try Self.composingWindow(marked: "にほん")
        defer { window.closeAfterTest() }
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        for (characters, keyCode) in [("\r", UInt16(36)), ("\u{1b}", 53), (down, 125), ("\t", 48)] {
            let event = try Self.key(characters, keyCode: keyCode, in: window)
            #expect(!palette.handleKeyDown(event, in: window), "the palette took key \(keyCode) from the input method")
        }
    }

    @Test func withoutMarkedTextThePaletteStillTakesReturn() throws {
        let palette = Self.palette()
        let window = try Self.composingWindow(marked: nil)
        defer { window.closeAfterTest() }
        #expect(palette.handleKeyDown(try Self.key("\u{1b}", keyCode: 53, in: window), in: window))
    }
}
