import XCTest

/// A reader scrolling up a long agent chat stays where they scrolled, all the way up. Leo,
/// 2026-11-19: "until we get the proper decent mobile app and the fucking scrolling behavior".
/// A chat past `AgentChatStore.windowTrigger` turns puts its older turns on disk while the reader
/// rests on the newest one (`ChatTranscriptList.spillIfResting`); scrolling up reads them back
/// above the reader. The transcript then measured the distance from the bottom against the content
/// height before those rows went in: the offset the list moved down by their height read as "at
/// the newest turn", following came back on, and the chat jumped to its bottom mid-scroll.
/// The Jump to bottom circle shows while the reader is away from the newest turn, so it must stay
/// after every drag up.
final class AgentChatOlderTurnsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testScrollingUpALongChatNeverJumpsToTheNewestTurn() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        // The list rig's chat: 200 replayed turns, held at the newest one (no passes).
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "chat"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "200"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_LEAVE_NEWEST"] = "0"
        app.launchEnvironment["CMUX_MOBILE_LIST_LARGE_DIFF"] = "0"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.navigationBars.buttons["More"].firstMatch.waitForExistence(timeout: 60),
                      "the stress chat opens\n\(app.debugDescription)")
        // Resting on the newest turn: the turns past the window go to disk.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let jump = app.buttons["Jump to bottom"].firstMatch
        XCTAssertFalse(jump.exists, "the chat opens on its newest turn")
        attach(app, "newest")

        // Up, a short drag at a time (no fling), far past the turns kept in memory.
        for drag in 1...60 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                       withVelocity: XCUIGestureVelocity(600), thenHoldForDuration: 0.05)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            XCTAssertEqual(app.state, .runningForeground, "the app is still running after drag \(drag)")
            if !jump.exists {
                attach(app, "jumped-after-drag-\(drag)")
                XCTFail("drag \(drag) up: the chat jumped back to its newest turn (no Jump to bottom)\n\(app.debugDescription)")
                return
            }
            if drag % 20 == 0 { attach(app, "up-\(drag)") }
        }

        // And Jump to bottom still takes the reader to the newest turn.
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "Jump to bottom reached the newest turn")
        attach(app, "back-to-newest")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
