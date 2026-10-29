import AppKit
@testable import CmuxNextTerminal
import CmuxNextWakeups
import Foundation
import GhosttyNextKit
import Testing

/// A terminal restored after a relaunch takes its theme on first show. That first apply must
/// land its colors at once: animating it blends the surface from the colors it has not painted
/// yet (white on a light-variant config) to the theme, which reads as white terminals that
/// settle a moment later.
@MainActor @Suite(.serialized) struct TerminalFirstThemeApplyTests {
    @Test func aFirstThemeApplyToAFreshTerminalIsNotAnimated() throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        let text = """
        background = #282a36
        foreground = #f8f8f2

        """
        let config = try #require(ghostty_config_new())
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "cmux-next-test") }
        ghostty_config_finalize(config)
        let theme = GhosttyThemeConfig(config: config, themeName: "cmux-next-test", colors: nil)

        let io = ScriptedTerminalIO(answersTerminalQueries: false)
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        defer { io.finish() }

        session.setTheme(theme)

        #expect(session.lastThemeApplyAnimated == false, "the first theme apply blended from the unpainted surface")
    }
}
