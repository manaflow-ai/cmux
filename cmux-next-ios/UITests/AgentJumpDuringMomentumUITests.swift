import XCTest

/// Jump to bottom tapped while a fling up the agent chat is still gliding lands on the newest
/// turn and stays there. Leo, iPhone, 2026-11-12: "when you click it, like if you already have
/// momentum scrolling up, like it doesn't fully jump to the bottom. It, like, just maintains
/// momentum and it doesn't, like, break the momentum and jump to bottom immediately." The jump
/// wrote `contentOffset` (which does not stop a deceleration): the transcript was placed at the
/// bottom, the fling carried on from there, and the circle came back short of the bottom.
/// An XCUITest tap waits for the app to go idle, so it would land only after the fling stops:
/// `-cmux-mobile-jump-mid-fling` has the app run Jump to bottom's own action 120 ms after the
/// release, while it still glides. Without the jump the fling leaves the circle shown.
final class AgentJumpDuringMomentumUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testJumpDuringFlingLandsOnNewestTurn() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "disclosure-chat", "-cmux-mobile-jump-mid-fling"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.navigationBars.buttons["More"].firstMatch.waitForExistence(timeout: 30),
                      "the pushed agent chat opens\n\(app.debugDescription)")
        let jump = app.buttons["Jump to bottom"].firstMatch

        // Three rounds: each flings up hard and releases with no hold; the app jumps mid-glide.
        for round in 1...3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.02, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)),
                       withVelocity: XCUIGestureVelocity(5000), thenHoldForDuration: 0)
            // At the bottom the circle leaves; a fling still running would carry the
            // transcript back up and show it again.
            XCTAssertTrue(jump.waitForNonExistence(timeout: 3), "round \(round): the jump reached the newest turn")
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            XCTAssertFalse(jump.exists, "round \(round): still at the newest turn 1.5 s later (the fling did not carry on)")
            attach(app, "round-\(round)-after-jump")
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
