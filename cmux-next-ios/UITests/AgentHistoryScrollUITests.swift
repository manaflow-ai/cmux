import XCTest

/// Scrolling an agent chat up through its history's other-agent messages (the mock history's
/// relayed report, three-message digest and Chief task, MockAgentSession+Parity.swift) keeps the
/// app running. A header capsule called as `tag("…")` resolved to SwiftUI's `View.tag(_:)`, which
/// drew the whole message card inside itself without end: the app crashed with a stack overflow as
/// soon as the list laid out (or prefetched) such a row. Both transcript paths: the native rows
/// (standard text size) and the SwiftUI rows (accessibility sizes).
final class AgentHistoryScrollUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testScrollingUpThroughAgentMessagesNativeRows() {
        run(name: "native", arguments: [])
    }

    @MainActor
    func testScrollingUpThroughAgentMessagesSwiftUIRows() {
        run(name: "swiftui", arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"])
    }

    @MainActor
    private func run(name: String, arguments: [String]) {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "disclosure-chat"] + arguments
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.navigationBars.buttons["More"].firstMatch.waitForExistence(timeout: 30),
                      "the pushed agent chat opens\n\(app.debugDescription)")

        // Up to the top of the history, one drag at a time; the app must still be running after each.
        let chief = app.descendants(matching: .any)["agent-chat.chief-bubble"].firstMatch
        let digest = app.staticTexts["3 messages"].firstMatch
        var sawChief = false
        var sawDigest = false
        for drag in 0..<30 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)))
            XCTAssertEqual(app.state, .runningForeground, "the app is still running after drag \(drag + 1)")
            sawChief = sawChief || chief.exists
            sawDigest = sawDigest || digest.exists
            if sawChief, sawDigest, drag >= 20 { break }
        }
        XCTAssertTrue(sawChief, "the Chief's bubble was scrolled past\n\(app.debugDescription)")
        XCTAssertTrue(sawDigest, "the three-message digest card was scrolled past\n\(app.debugDescription)")
        attach(app, "\(name)-history-top")

        // And back down to the newest row: every row is laid out again on the way.
        for _ in 0..<30 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        }
        XCTAssertEqual(app.state, .runningForeground, "the app is still running at the newest row")
        attach(app, "\(name)-history-bottom")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
