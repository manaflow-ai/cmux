import Foundation
import Testing
@testable import CmuxTmuxControlMode

@Suite("tmux control mode snapshots")
struct TmuxControlModeSnapshotTests {
    private let state = "cursor_x=2,cursor_y=1,scroll_region_upper=3,scroll_region_lower=20,cursor_flag=1,insert_flag=0,keypad_cursor_flag=1,keypad_flag=0,wrap_flag=1,origin_flag=1,pane_height=24,mouse_all_flag=0,mouse_button_flag=1,mouse_standard_flag=0,mouse_sgr_flag=1,mouse_utf8_flag=0"

    @Test("replacement frames preserve rows and restore terminal state")
    func rendersReplacementFrame() {
        let bytes = TmuxControlModeSnapshot.render(
            lines: ["top", "bottom"],
            alternateScreen: true,
            stateLine: state
        )
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix("\u{1b}c\u{1b}[3J\u{1b}[?1049l\u{1b}[?1049h\u{1b}[H\u{1b}[2Jtop\r\nbottom"))
        #expect(text.contains("\u{1b}[4;21r"))
        #expect(text.contains("\u{1b}[?1002h\u{1b}[?1006h"))
        #expect(text.hasSuffix("\u{1b}[1;3H"))
    }

    @Test("all replacement sources share the reset prefix, including empty frames")
    func replacementPrefixIsStable() {
        #expect(TerminalSessionSnapshot.replacementPrefix == [
            0x1B, 0x63, 0x1B, 0x5B, 0x33, 0x4A,
        ])
        #expect(TerminalSessionSnapshot.replacing([]) == TerminalSessionSnapshot.replacementPrefix)
        #expect(TerminalSessionSnapshot.replacing([0x78]) == [
            0x1B, 0x63, 0x1B, 0x5B, 0x33, 0x4A, 0x78,
        ])
    }

    @Test("invalid state values are ignored without integer traps")
    func ignoresInvalidStateValues() {
        let bytes = TmuxControlModeSnapshot.stateSequence(
            from: "cursor_x=999999999999999999999,cursor_y=-1,scroll_region_upper=oops"
        )
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("\u{1b}[?6l"))
        #expect(!text.contains("H"))
    }
}
