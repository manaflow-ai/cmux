import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextTerminal
import Testing

/// Which keys the user's Ghostty config claims for itself (a terminal
/// action or `unbind`), read from Ghostty's own binding set with real
/// config text (PANE-FOCUS-RESIZE-KEYS-AND-GHOSTTY-KEYBINDS).
@MainActor
struct GhosttyKeyClaimsTests {
    /// Ctrl-Shift-H: no Ghostty default.
    static let controlShiftH = GhosttyKeyProbe(keyCode: 4, unshifted: 104, modifiers: [.control, .shift])
    /// Cmd-D: Ghostty's macOS default `super+d=new_split:right`.
    static let commandD = GhosttyKeyProbe(keyCode: 2, unshifted: 100, modifiers: [.command])

    static func claimed(_ text: String) -> [Bool] {
        _ = GhosttyRuntime.shared
        return GhosttyKeyClaims.claimed([controlShiftH, commandD], configText: text)
    }

    @Test func noUserLinesClaimNothing() {
        #expect(Self.claimed("") == [false, false])
    }

    @Test func aTerminalActionClaimsItsKey() {
        #expect(Self.claimed("keybind = ctrl+shift+h=text:\\x08\n") == [true, false])
    }

    /// `unbind` of a key Ghostty never bound changes nothing in Ghostty's
    /// set; cmux reads the line itself and still gives the key away.
    @Test func anUnbindOfAKeyGhosttyNeverBoundClaimsIt() {
        #expect(Self.claimed("keybind = ctrl+shift+h=unbind\n") == [true, false])
    }

    @Test func anUnbindOfAGhosttyDefaultClaimsIt() {
        #expect(Self.claimed("keybind = super+d=unbind\n") == [false, true])
    }

    /// A user keybind to a routed action claims its key too (the routed
    /// entry runs above it); a commented or sequence `unbind` claims nothing.
    @Test func routedLinesClaimAndCommentsOrSequencesDoNot() {
        #expect(Self.claimed("keybind = ctrl+shift+h=goto_split:left\n") == [true, false])
        #expect(Self.claimed("# keybind = ctrl+shift+h=unbind\n") == [false, false])
        #expect(Self.claimed("keybind = ctrl+b>ctrl+shift+h=unbind\n") == [false, false])
    }

    /// The probe of a table key: the physical key that types it and its
    /// codepoint; arrows type nothing (codepoint 0).
    @Test func tableKeysBecomeGhosttyProbes() {
        let names: [UInt16: String] = [4: "h", 123: Shortcut.leftArrowKey]
        let h = GhosttyKeyBindingLayer.probe(for: Shortcut("h", modifiers: [.control, .shift]), keyNames: names)
        #expect(h == GhosttyKeyProbe(keyCode: 4, unshifted: 104, modifiers: [.control, .shift]))
        let left = GhosttyKeyBindingLayer.probe(for: Shortcut(Shortcut.leftArrowKey, modifiers: [.command, .control]), keyNames: names)
        #expect(left == GhosttyKeyProbe(keyCode: 123, unshifted: 0, modifiers: [.command, .control]))
        #expect(GhosttyKeyBindingLayer.probe(for: Shortcut("q", modifiers: [.command]), keyNames: names) == nil)
    }
}
