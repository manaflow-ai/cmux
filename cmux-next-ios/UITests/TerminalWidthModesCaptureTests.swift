import XCTest

/// Captures for Leo's choice of how the phone shows a Mac terminal that is
/// narrower or wider than the phone: A resize (the Mac's PTY takes the
/// phone's size), B reflow (the phone re-wraps; the Mac keeps its size), or
/// mixed (resize for full-screen apps and Claude Code, reflow for a shell).
/// The same suite runs on each variant's branch.
///
/// Each test opens the terminal demo's `widthcapture` phase
/// (`TerminalWidthCaptureDemo`): a Mac pane of N columns running Claude Code
/// (inline, primary screen), vim (alternate screen) or plain shell output.
/// It takes one screenshot attached, one with the keyboard shown and one
/// after it hid. Each attachment's name carries the content, the pane's
/// columns, the stage and the Mac PTY's grid at that moment.
final class TerminalWidthModesCaptureTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor func testClaudeNarrow() throws { try capture(.claude, columns: 39) }
    @MainActor func testClaudeWide() throws { try capture(.claude, columns: 120) }
    @MainActor func testVimNarrow() throws { try capture(.vim, columns: 39) }
    @MainActor func testVimWide() throws { try capture(.vim, columns: 120) }
    @MainActor func testShellNarrow() throws { try capture(.shell, columns: 39) }
    @MainActor func testShellWide() throws { try capture(.shell, columns: 120) }

    enum Content: String { case claude, vim, shell }

    @MainActor
    private func capture(_ content: Content, columns: Int) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "widthcapture",
                                "-CmuxMobileWidthCaptureContent", content.rawValue,
                                "-CmuxMobileWidthCaptureColumns", String(columns)]
        app.launch()
        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")
        var lines: [String] = []
        for stage in ["attached", "kbshown", "kbhidden"] {
            let deadline = Date().addingTimeInterval(40)
            var label = probe.label
            while !label.hasPrefix("w.\(stage)."), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                label = probe.label
            }
            guard label.hasPrefix("w.\(stage).") else {
                XCTFail("\(content) \(columns): never reached \(stage) (\(label))")
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            // e.g. "claude-39col-1-attached pty39x40.rz0"
            let index = lines.count + 1
            let name = "\(content.rawValue)-\(columns)col-\(index)-\(stage) " + label.dropFirst("w.\(stage).".count)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            lines.append(name)
            print("width capture: \(name)")
        }
        app.terminate()
    }
}
