import XCTest

/// Leo, 2026-11-14: "I tried to open up a link on the terminal on iOS. And a direct open link
/// one. It opened in Alma on Mac". The link demo (`-CmuxMobileLinkDemo`: the real terminal page
/// and session against a scripted Mac daemon) types `open URL` from the phone; the Mac sends
/// `phone-open-link` and the link opens in the Safari view over the terminal.
final class TerminalLinkDemoUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testALinkAProgramOpensShowsOnThePhone() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-CmuxMobileLinkDemo"]
        app.launch()

        let probe = app.staticTexts["debug.link-demo"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the link demo's step label\n\(app.debugDescription)")
        var step = ""
        var shotTyped = false
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !step.hasPrefix("done.") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            step = probe.label
            if step == "attached", !shotTyped {
                attach(app, "1-terminal-before")
                shotTyped = true
            }
        }
        attach(app, "2-after-open")
        print("link demo: \(step)")
        let note = XCTAttachment(string: step)
        note.name = "demo-step"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertTrue(step.hasPrefix("done.safari"), "the link opened in the Safari view on the phone (\(step))")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
