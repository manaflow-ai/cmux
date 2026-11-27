import XCTest

/// Captures another agent's message in the shipping app's offline DEBUG chat (the mock history's
/// relayed report and three-message digest, MockAgentSession+Parity.swift): the sender's card at
/// the left, no envelope text, and the digest's stack opened in place. Light and dark.
final class AgentIncomingCaptureUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAgentMessageCardsCapture() {
        for appearance in [XCUIDevice.Appearance.dark, .light] {
            XCUIDevice.shared.appearance = appearance
            let name = appearance == .dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            // The app's own Appearance setting (system by default) draws the mode asked for.
            app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmuxMobile.settings.appearance", name,
                                    "-cmux-mobile-demo", "disclosure-chat"]
            app.launch()

            let more = app.navigationBars.buttons["More"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 30), "the pushed agent chat opens\n\(app.debugDescription)")

            // The digest's card sits above the subagent turn: scroll up to it.
            let digest = app.staticTexts["3 messages"].firstMatch
            for _ in 0..<12 where !digest.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
            }
            XCTAssertTrue(digest.isHittable, "the digest's card shows\n\(app.debugDescription)")
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'an agent, not Leo'")).firstMatch.exists,
                           "no envelope text is drawn")
            attach(app, "agent-cards-\(name)")

            let first = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'build-box/lane-3'")).firstMatch
            XCTAssertTrue(first.waitForExistence(timeout: 5), "the stack's first line\n\(app.debugDescription)")
            first.tap()
            let opened = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'CI is running'")).firstMatch
            XCTAssertTrue(opened.waitForExistence(timeout: 5), "the line opens its message")
            attach(app, "agent-digest-open-\(name)")
            app.terminate()
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
