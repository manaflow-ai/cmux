import AppKit
@testable import CmuxNextTerminal
import Testing

/// The rule that sends a Cmd-click on a link to cmux while a program has the mouse (u11857).
@Suite struct TerminalPointerModsTests {
    @Test func commandAloneInACaptureLooksForLinksAndClicksOnlyOnOne() {
        let off = TerminalPointerMods(captured: true, overLink: false, linkPress: false)
        let on = TerminalPointerMods(captured: true, overLink: true, linkPress: false)
        #expect(off.flags(.command, phase: .move) == [.command, .shift])
        #expect(off.flags(.command, phase: .press) == .command)
        #expect(on.flags(.command, phase: .press) == [.command, .shift])
        #expect(on.flags(.command, phase: .followingPress) == .command)
        let pressed = TerminalPointerMods(captured: true, overLink: true, linkPress: true)
        #expect(pressed.flags(.command, phase: .followingPress) == [.command, .shift])
        // Command let go before the release: the click still ends as the link click it began as.
        #expect(pressed.flags([], phase: .followingPress) == .shift)
    }

    @Test(arguments: [NSEvent.ModifierFlags([]), .shift, [.command, .control], [.control], [.option, .shift], [.option, .control]])
    func otherKeysStayAsTheyAre(_ flags: NSEvent.ModifierFlags) {
        let mods = TerminalPointerMods(captured: true, overLink: true, linkPress: false)
        for phase in [TerminalPointerMods.Phase.move, .press, .followingPress] {
            #expect(mods.flags(flags, phase: phase) == flags)
        }
    }

    @Test func withoutACaptureNothingChanges() {
        let mods = TerminalPointerMods(captured: false, overLink: true, linkPress: false)
        #expect(mods.flags(.command, phase: .move) == .command)
        #expect(mods.flags(.command, phase: .press) == .command)
    }

    /// Without a capture, Shift- and Option-Command go as Command alone while they hover a link,
    /// press on one and finish that press, so Ghostty matches it; the open reads the real keys.
    @Test(arguments: [NSEvent.ModifierFlags([.command, .shift]), [.command, .option]])
    func commandChordsWithoutACaptureMatchLinksAsCommand(_ flags: NSEvent.ModifierFlags) {
        let off = TerminalPointerMods(captured: false, overLink: false, linkPress: false)
        #expect(off.flags(flags, phase: .move) == .command)
        #expect(off.flags(flags, phase: .press) == flags)
        let on = TerminalPointerMods(captured: false, overLink: true, linkPress: false)
        #expect(on.flags(flags, phase: .press) == .command)
        #expect(on.flags(flags, phase: .followingPress) == flags)
        let pressed = TerminalPointerMods(captured: false, overLink: true, linkPress: true)
        #expect(pressed.flags(flags, phase: .followingPress) == .command)
        #expect(pressed.flags([.command, .control], phase: .move) == [.command, .control])
    }

    /// While the program has the mouse, Shift- and Option-Command go as Command with the Shift
    /// override, so Ghostty finds the link there too (Option kept would match none).
    @Test(arguments: [NSEvent.ModifierFlags([.command, .shift]), [.command, .option]])
    func commandChordsInACaptureMatchLinksAsCommandWithTheOverride(_ flags: NSEvent.ModifierFlags) {
        let off = TerminalPointerMods(captured: true, overLink: false, linkPress: false)
        #expect(off.flags(flags, phase: .move) == [.command, .shift])
        #expect(off.flags(flags, phase: .press) == flags)
        let on = TerminalPointerMods(captured: true, overLink: true, linkPress: false)
        #expect(on.flags(flags, phase: .press) == [.command, .shift])
        let pressed = TerminalPointerMods(captured: true, overLink: true, linkPress: true)
        #expect(pressed.flags(flags, phase: .followingPress) == [.command, .shift])
    }

    /// An Option-drag selects text while the program has the mouse, as in other Mac terminals: its press
    /// goes with Ghostty's Shift override in place of Option, and so do its drags and release, also once
    /// Option is let go. A move without a button keeps Option.
    @Test func optionDragInACaptureSelectsWithTheShiftOverride() {
        let mods = TerminalPointerMods(captured: true, overLink: false, linkPress: false)
        #expect(mods.selectionGesture(.option, phase: .press))
        #expect(mods.flags(.option, phase: .press) == .shift)
        #expect(mods.flags(.option, phase: .move) == .option)
        let pressed = TerminalPointerMods(captured: true, overLink: false, linkPress: false, selectionPress: true)
        #expect(pressed.flags(.option, phase: .followingPress) == .shift)
        #expect(pressed.flags([], phase: .followingPress) == .shift)
    }

    /// Without a capture Option-drag stays Ghostty's rectangle selection, and Option-Shift stays the
    /// rectangle override in a capture.
    @Test func optionDragWithoutACaptureStaysARectangleSelection() {
        let free = TerminalPointerMods(captured: false, overLink: false, linkPress: false)
        #expect(!free.selectionGesture(.option, phase: .press))
        #expect(free.flags(.option, phase: .press) == .option)
        let captured = TerminalPointerMods(captured: true, overLink: false, linkPress: false)
        #expect(captured.flags([.option, .shift], phase: .press) == [.option, .shift])
    }
}
