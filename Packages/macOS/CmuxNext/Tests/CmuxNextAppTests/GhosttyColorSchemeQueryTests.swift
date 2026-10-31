import AppKit
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import GhosttyNextKit
import Testing

/// cx-y1qa0: a terminal with a plain theme (one theme for light and dark, like `theme = Dracula`) in
/// dark mode must answer the color scheme query `CSI ? 996 n` with dark (`CSI ? 997 ; 1 n`).
/// Ghostty answered from the config's conditional state, which a config only follows when its
/// theme is a light/dark pair with different sides, so a plain theme always answered light.
/// Drives a real Ghostty surface whose IO does not answer queries itself (`GHOSTTY_SURFACE_IO_MANUAL`,
/// a local PTY's mode), so Ghostty writes the reply back to the IO.
@MainActor @Suite(.serialized, .closesItsWindows) struct GhosttyColorSchemeQueryTests {
    @Test func aPlainDarkThemeInDarkModeReportsDark() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        // Dracula's colors with no theme pair: what `theme = Dracula` resolves to. A fresh config
        // keeps the runner's own Ghostty config out.
        let text = """
        background = #282a36
        foreground = #f8f8f2

        """
        let config = try #require(ghostty_config_new())
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "cmux-next-test") }
        ghostty_config_finalize(config)
        let theme = GhosttyThemeConfig(config: config, themeName: "cmux-next-test", colors: nil)

        let io = ScriptedTerminalIO(answersTerminalQueries: false)
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            io.finish()
            window.close()
        }
        window.contentView = session.view
        session.view.layoutSubtreeIfNeeded()

        // The scheme push every live surface gets when the app turns dark (GhosttyRuntime.applyColorScheme).
        // Its soft config reload hands the surface the app config, so the theme goes on after it, as
        // the app's onConfigChange does.
        session.surfaceView.applyColorScheme(dark: true)
        #expect(session.surfaceIsDark)
        session.setTheme(theme)

        // The plain theme is live once OSC 11 reports its background.
        let background = "rgb:2828/2a2a/3636"
        let themed = try await Self.reply(from: io, after: "\u{1b}]11;?\u{1b}\\") { $0.contains(background) }
        #expect(themed.contains(background), "the plain theme never reached the surface: \(themed.debugDescription)")

        let dark = "\u{1b}[?997;1n"
        let light = "\u{1b}[?997;2n"
        let report = try await Self.reply(from: io, after: "\u{1b}[?996n") { $0.contains(dark) || $0.contains(light) }
        #expect(report.contains(dark), "a dark surface with a plain theme reported \(report.debugDescription)")
    }

    /// Sends `query` as program output and waits up to 10 seconds for the bytes Ghostty writes back
    /// to satisfy `done`. Returns everything written since the query.
    static func reply(from io: ScriptedTerminalIO, after query: String,
                      until done: (String) -> Bool) async throws -> String {
        let start = io.writes.count
        io.send(.output(Data(query.utf8)))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var written = ""
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            written = String(decoding: io.writes.dropFirst(start).reduce(Data(), +), as: UTF8.self)
            if done(written) { break }
        }
        return written
    }
}
