import XCTest

/// CMUX-10: in a workspace's agent tab (TabsKit chrome) the jump to bottom
/// circle sits just above the composer, in both toolbar states. Before the fix
/// it sat 54 pt above it (simulator, both states; about 50 pt on the person's
/// iPhone): the stack's first height was placed without animation, so it never
/// reached the dock guide the circle hangs from, which kept its 96 pt default
/// for a 56 pt composer until some later animated change.
final class AgentTabJumpGapUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testJumpGapFollowsComposerAcrossToolbarCollapse() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "kbd-tab"]
        app.launch()
        defer { app.terminate() }

        // At rest the composer is its collapsed capsule ("Reply to Claude").
        let field = app.buttons["Reply to Claude"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the agent tab's composer\n\(app.debugDescription)")
        let jump = app.buttons["Jump to bottom"].firstMatch

        // Finger down reveals older turns (and expands the toolbar).
        for _ in 0..<4 where !(jump.exists && jump.isHittable) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        expect(jump, "exists == true AND hittable == true", "scrolled away: the jump circle shows")
        settle(jump)
        let expandedGap = field.frame.minY - jump.frame.maxY
        attach(app, "toolbar-expanded")

        // A short finger-up drag collapses the toolbar into its pill and stays
        // far from the bottom, so the circle stays.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        settle(jump)
        expect(jump, "exists == true", "still away from the bottom")
        let collapsedGap = field.frame.minY - jump.frame.maxY
        attach(app, "toolbar-collapsed")

        XCTAssertGreaterThan(expandedGap, 0, "the circle never overlaps the composer field (expanded)")
        XCTAssertGreaterThan(collapsedGap, 0, "the circle never overlaps the composer field (collapsed)")
        XCTAssertLessThan(collapsedGap, 30, "with the pill the circle sits just above the composer, not \(collapsedGap) pt away")
        XCTAssertLessThan(expandedGap, 30, "with the toolbar the circle sits just above the composer, not \(expandedGap) pt away")
        XCTAssertEqual(collapsedGap, expandedGap, accuracy: 4, "the same gap in both toolbar states")
    }

    /// The toolbar's spring has landed: the circle's frame stops moving
    /// between two reads (up to 5 s), instead of a fixed pause.
    @MainActor
    private func settle(_ element: XCUIElement) {
        var last = element.frame
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let now = element.frame
            if abs(now.minY - last.minY) < 0.5 { return }
            last = now
        }
    }

    @MainActor
    private func expect(_ element: XCUIElement, _ predicate: String, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed, message)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
