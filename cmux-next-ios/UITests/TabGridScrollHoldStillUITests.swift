import XCTest

/// Leo (2026-11-22): "why do things move when i scroll around and the momentum gets kept?
/// that shouldnt happen. theres no reason for the previewed things to move like that." Opens
/// a 29-tab workspace's grid (the list stress rig's tabs case, mock data), then flings it down
/// and up like a finger, with screenshots while it decelerates and at rest. Run with `video`
/// for the before/after recording: no card's preview may change size, place or content while
/// the grid moves.
final class TabGridScrollHoldStillUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFlingingTheGridKeepsEveryPreviewStill() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_LIST_SCREEN"] = "tabs"
        app.launchEnvironment["CMUX_MOBILE_LIST_COUNT"] = "29"
        app.launchEnvironment["CMUX_MOBILE_LIST_PASSES"] = "0"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-tab", "workspaces"]
        app.launch()
        defer { app.terminate() }

        let count = app.staticTexts["29 Tabs"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 60), "the 29-tab grid\n\(app.debugDescription)")
        pause(3.0)
        attach(app, "0-grid-at-rest")
        let atRest = cardCorners(app)
        XCTAssertGreaterThanOrEqual(atRest.count, 4, "the grid's first cards, by their Close buttons")
        assertTwoColumns(atRest, "at rest")

        let window = app.windows.firstMatch
        let low = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let high = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        for round in 1 ... 2 {
            for (direction, from, to) in [("down", low, high), ("up", high, low)] {
                for fling in 0 ..< 3 {
                    // A quick flick: the grid keeps going on its own momentum.
                    from.press(forDuration: 0.01, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
                    for frame in 0 ..< 3 {
                        attach(app, "\(round)-\(direction)-\(fling)-decelerating-\(frame)")
                        pause(0.15)
                    }
                }
                pause(2.0)
                attach(app, "\(round)-\(direction)-rest")
                let corners = cardCorners(app)
                assertTwoColumns(corners, "round \(round) after flinging \(direction)")
                // Back at the top, every card sits where it sat before the flings.
                if direction == "up" {
                    XCTAssertEqual(corners.count, atRest.count, "round \(round): the cards on screen changed: \(corners)")
                    for (now, before) in zip(corners, atRest) {
                        XCTAssertLessThanOrEqual(max(abs(now.x - before.x), abs(now.y - before.y)), 1,
                                                 "round \(round): a card changed place or size: \(corners) was \(atRest)")
                    }
                }
            }
        }
        XCTAssertTrue(count.exists, "the grid is still up")
    }

    /// Where each visible card's Close button sits, in reading order: a card that
    /// changed size or place moves its corner.
    @MainActor
    private func cardCorners(_ app: XCUIApplication) -> [CGPoint] {
        // By frame, not by hittable: the bars at the top and bottom cover some
        // cards' buttons, and a covered card still must not move.
        let screen = app.windows.firstMatch.frame
        return app.buttons.matching(NSPredicate(format: "label == 'Close'")).allElementsBoundByIndex
            .filter(\.exists)
            .map { CGPoint(x: $0.frame.midX.rounded(), y: $0.frame.midY.rounded()) }
            .filter { screen.contains($0) }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    /// Cards form two columns with one row pitch: no card grew, shrank or slid.
    private func assertTwoColumns(_ corners: [CGPoint], _ when: String) {
        XCTAssertEqual(Set(corners.map(\.x)).count, 2, "\(when): cards are not in two columns: \(corners)")
        let rows = Array(Set(corners.map(\.y))).sorted()
        let pitches = zip(rows, rows.dropFirst()).map { $1 - $0 }
        XCTAssertLessThanOrEqual((pitches.max() ?? 0) - (pitches.min() ?? 0), 2, "\(when): rows are not evenly spaced: \(rows)")
    }

    @MainActor
    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
