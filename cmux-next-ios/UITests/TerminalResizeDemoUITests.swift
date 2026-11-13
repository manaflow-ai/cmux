import XCTest

/// Aziz, 2026-11-12: "ensure that the phone never sees a terminal size that
/// it doesn't want to see even if it receives it. This would otherwise cause
/// momentary incorrect size drawings". The resize demo (`-CmuxMobileResizeDemo`:
/// the real terminal page and session against a scripted Mac with a 120x40
/// pane) sends the Mac's grid while the page is on screen, then backgrounds
/// and foregrounds the app. Screenshots at each step; the step script's video
/// (`cmux-next-ios-sim.sh test ... video`) shows every frame in between.
final class TerminalResizeDemoUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testTheMacsGridIsNeverDrawnOnThePhone() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileResizeDemo"]
        app.launch()

        let probe = app.staticTexts["debug.resize-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the resize demo's step label\n\(app.debugDescription)")

        // (step, delay after it starts, screenshot name)
        let shots: [(String, Double, String)] = [
            ("phone", 1.0, "1-phone-grid"),
            ("lease", 0.15, "2-mac-grid-sent-150ms"),
            ("lease", 0.6, "3-mac-grid-sent-600ms"),
            ("lease", 2.0, "4-mac-grid-sent-2s"),
            ("foreground", 0.15, "5-foreground-150ms"),
            ("foreground", 2.0, "6-foreground-2s"),
        ]
        var taken: Set<String> = []
        var started: [String: Date] = [:]
        var step = ""
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !step.hasPrefix("done.") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            step = probe.label
            if started[step] == nil { started[step] = Date() }
            for (name, delay, shot) in shots where name == step && !taken.contains(shot) {
                if let start = started[name], Date().timeIntervalSince(start) >= delay {
                    attach(app, shot)
                    taken.insert(shot)
                }
            }
        }
        print("resize demo: \(step)")
        XCTContext.runActivity(named: "demo: \(step)") { _ in }
        XCTAssertTrue(step.hasPrefix("done."), "the demo finished (\(step))")
        XCTAssertEqual(taken.count, shots.count, "every step was captured (\(taken.sorted()))")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
