import XCTest

/// Leo, 2026-11-15: "i meant previously there was the thing that stopped the
/// resizing when you closed the ios built in keyboard". Showing or closing
/// the soft keyboard never resizes the Mac's PTY (#41895, taken back by
/// #42760): a full-screen app keeps its keyboard-down rows, and with the
/// keyboard up its grid is inset, lifted only as far as the cursor's row needs.
///
/// The terminal demo's `kbtui` phase (mock session, the workspace tab page)
/// opens vim and shows and hides the keyboard five times; its last step reads
/// `done.rz<before>-<after>`, the grid sizes the page sent before and after.
final class TerminalKeyboardNoResizeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheKeyboardNeverResizesAFullScreenApp() throws {
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
                // The keyboard's animation and the resize settle are over by
                // then; the next step is 2.5 s after this one.
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
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
        // Ten keyboard toggles, no resize: the Mac's app never redraws for them.
        XCTAssertEqual(counts.last, counts.first, "the keyboard resized the full-screen app (\(demo))")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
