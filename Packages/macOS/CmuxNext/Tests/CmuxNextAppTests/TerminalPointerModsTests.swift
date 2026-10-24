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

    @Test(arguments: [NSEvent.ModifierFlags([]), .shift, [.command, .option], [.command, .control], [.command, .shift]])
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
}
