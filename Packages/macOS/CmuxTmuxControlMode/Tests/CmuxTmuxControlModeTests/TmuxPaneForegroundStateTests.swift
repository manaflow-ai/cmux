import Testing
@testable import CmuxTmuxControlMode

@Suite("tmux foreground resize policy")
struct TmuxPaneForegroundStateTests {
    @Test func shellReflowsIncludingLoginShellSpelling() {
        #expect(TmuxPaneForegroundState(rawValue: "0|zsh").resizePolicy == .reflow)
        #expect(TmuxPaneForegroundState(rawValue: "0|-bash").resizePolicy == .reflow)
    }

    @Test func alternateAndUnknownCommandsPreservePaintedScreen() {
        #expect(TmuxPaneForegroundState(rawValue: "1|zsh").resizePolicy == .preserveScreen)
        #expect(TmuxPaneForegroundState(rawValue: "0|nvim").resizePolicy == .preserveScreen)
        #expect(TmuxPaneForegroundState(rawValue: "").resizePolicy == .preserveScreen)
    }
}
