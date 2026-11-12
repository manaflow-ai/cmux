import XCTest

/// Leo, 2026-11-12: "the resizing is so wack when j tap the thijg". Tapping
/// the key row's keyboard key resized the Mac's PTY: the full-screen app
/// redrew at other rows and the page jumped. The keyboard now insets the
/// page and the grid keeps its size.
///
/// The terminal demo's `kbtui` phase (mock session, the workspace tab page)
/// opens vim and shows and hides the keyboard five times; its last step reads
/// `done.rz<before>-<after>`, the grid sizes the page sent before and after.
final class TerminalKeyboardNoResizeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testKeyboardTogglesNeverResizeTheTerminal() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", "kbtui"]
        app.launch()

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")

        // A screenshot once each keyboard state has settled (the first round).
        var shot: Set<String> = []
        var demo = ""
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !demo.hasPrefix("done.") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            demo = probe.label
            for step in ["tui.", "show0", "hide0"] where demo.hasPrefix(step) && !shot.contains(step) {
                // The keyboard's animation is over by then; the next step is 1.6 s after this one.
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                attach(app, step == "tui." ? "vim-keyboard-down" : step == "show0" ? "vim-keyboard-up" : "vim-keyboard-down-again")
                shot.insert(step)
            }
        }
        print("kbd-tui demo: \(demo)")
        XCTContext.runActivity(named: "demo: \(demo)") { _ in }
        XCTAssertTrue(demo.hasPrefix("done.rz"), "the demo finished with vim on the alternate screen (\(demo))")
        XCTAssertTrue(shot.isSuperset(of: ["tui.", "show0", "hide0"]), "each keyboard state was captured (\(shot.sorted()), \(demo))")
        let counts = demo.dropFirst("done.rz".count).split(separator: "-").compactMap { Int($0) }
        XCTAssertEqual(counts.count, 2, "resize counts in \(demo)")
        XCTAssertGreaterThan(counts.first ?? 0, 0, "the page claimed its grid on attach (\(demo))")
        XCTAssertEqual(counts.first, counts.last, "showing or hiding the keyboard resized the terminal (\(demo))")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
