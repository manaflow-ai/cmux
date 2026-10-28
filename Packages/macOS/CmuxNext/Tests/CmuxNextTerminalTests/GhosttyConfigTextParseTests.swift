@testable import CmuxNextTerminal
import Foundation
import GhosttyNextKit
import Testing

/// The parsers of text and payloads from outside the app (a Ghostty config file's `keybind`
/// and `font-family` lines, an action's URL length) read from the front with no subscript and convert with
/// `exactly:`, so no line or length traps. Each keybind case is read the way Ghostty's binding parser reads it.
struct GhosttyConfigTextParseTests {
    @Test func keybindLinesNameTheirAction() {
        let text = """
        keybind = cmd+i=inspector:toggle
        keybind = global:all:cmd+r=redo
        # keybind = cmd+x=redo
        keybind = "ctrl+==toggle_quick_terminal"
        keybind = ctrl+=+a=float_window
        keybind = cmd+t=new_tab
        keybind=cmd+e=
        keybind
        keybind = ctrl+a=reset_window_size
        global:keybind = x=redo
        """
        let found = GhosttyRuntime.unsupportedKeybindActions(in: text)
        #expect(found.map { $0.0 } == [1, 2, 4, 5, 9])
        #expect(found.map { $0.1.name } == ["inspector", "redo", "toggle_quick_terminal", "float_window", "reset_window_size"])
    }

    @Test func fontFamilyLinesApplyInOrder() {
        let text = "font-family = Fira Code\n#font-family = No\nfont-family=\"JetBrains Mono\"\nfont-family-bold = X\nfont-family\nfont-family = a=b\n"
        #expect(GhosttyConfigFontFamily.fontFamilies(configText: text) == ["Fira Code", "JetBrains Mono", "a=b"])
        #expect(GhosttyConfigFontFamily.fontFamilies(configText: "font-family = A\nfont-family =\nfont-family = B", after: ["Z"]) == ["B"])
    }

    /// An OPEN_URL length past Int.max trapped in `Int(_:)`; the action decodes to nothing.
    @Test func anOpenURLLengthPastIntMaxDecodesToNothing() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_OPEN_URL
        let url = Array("https://example.com".utf8CString)
        let decoded: GhosttyAction? = url.withUnsafeBufferPointer { buffer in
            action.action.open_url.url = buffer.baseAddress
            action.action.open_url.len = UInt.max
            return GhosttyActionDecoder.decode(action)
        }
        #expect(decoded == nil)
    }
}
