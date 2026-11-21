import XCTest

/// Leo, 2026-11-15: "i meant previously there was the thing that stopped the
/// resizing when you closed the ios built in keyboard", then "add the top
/// exception? why roll the whole thing back". Showing or closing the soft
/// keyboard never resizes the Mac's PTY (#41895, taken back by #42760): a
/// full-screen app keeps its keyboard-down rows; with the keyboard up its
/// first rows stay pinned at the top and the body keeps the cursor's row.
///
/// The terminal demo's `kbtui` (vim) and `kbclaude` (a mock Claude Code
/// screen: header box on top, input box at the bottom) phases, on the
/// workspace tab page, show and hide the keyboard five times; the last step
/// reads `done.rz<before>-<after>`, the grid sizes the page sent before and after.
final class TerminalKeyboardNoResizeUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheKeyboardNeverResizesAFullScreenApp() throws {
        try runKeyboardRounds(phase: "kbtui", name: "vim")
    }

    /// The capture the review asked for: Claude Code's header above the
    /// keyboard, its input box on the keyboard.
    @MainActor
    func testClaudeCodesHeaderStaysAboveTheKeyboard() throws {
        try runKeyboardRounds(phase: "kbclaude", name: "claude")
    }

    @MainActor
    private func runKeyboardRounds(phase: String, name: String) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileTerminalDemo", "-CmuxMobileTerminalDemoEmbedded",
                                "-CmuxMobileTerminalDemoPhases", phase]
        app.launch()

        let probe = app.staticTexts["debug.terminal-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the terminal demo's step label\n\(app.debugDescription)")

        // A screenshot once each keyboard state has settled (the first round),
        // and the keyboard's state then: the toggles really showed and hid it.
        var shot: Set<String> = []
        var keyboardShown: [String: Bool] = [:]
        var demo = ""
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !demo.hasPrefix("done.") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            demo = probe.label
            for step in ["tui.", "show0", "hide0"] where demo.hasPrefix(step) && !shot.contains(step) {
                // The keyboard's animation and the resize settle are over by
                // then; the next step is 2.5 s after this one.
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                keyboardShown[step] = app.keyboards.firstMatch.exists
                attach(app, step == "tui." ? "\(name)-keyboard-down" : step == "show0" ? "\(name)-keyboard-up" : "\(name)-keyboard-down-again")
                shot.insert(step)
            }
        }
        print("kbd-tui demo (\(phase)): \(demo) keyboard: \(keyboardShown)")
        XCTContext.runActivity(named: "demo: \(demo)") { _ in }
        XCTAssertTrue(demo.hasPrefix("done.rz"), "the demo finished with \(name) on the alternate screen (\(demo))")
        XCTAssertTrue(shot.isSuperset(of: ["tui.", "show0", "hide0"]), "each keyboard state was captured (\(shot.sorted()), \(demo))")
        XCTAssertEqual(keyboardShown["show0"], true, "the keyboard toggle showed the soft keyboard (\(keyboardShown))")
        XCTAssertEqual(keyboardShown["hide0"], false, "the keyboard toggle hid the soft keyboard (\(keyboardShown))")
        // `done.rz<before>-<after>.steps=...`: the counts before the step log.
        let rz = demo.dropFirst("done.rz".count).split(separator: ".").first ?? ""
        let counts = rz.split(separator: "-").compactMap { Int($0) }
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
