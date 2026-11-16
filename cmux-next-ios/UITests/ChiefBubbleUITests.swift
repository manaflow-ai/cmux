import XCTest

/// CMUX-51: a message a Chief's turn sent an agent chat (acpmux `fromChief`, the mock history's
/// Chief task in MockAgentSession+Parity.swift) draws as the Chief's blue bubble under its name and a
/// "Chief" tag, never as the person's own grey bubble. Light and dark captures.
final class ChiefBubbleUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testChiefMessageIsTheChiefsBlueBubble() {
        for appearance in [XCUIDevice.Appearance.dark, .light] {
            XCUIDevice.shared.appearance = appearance
            let name = appearance == .dark ? "dark" : "light"
            let app = XCUIApplication()
            app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
            app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmuxMobile.settings.appearance", name,
                                    "-cmux-mobile-demo", "disclosure-chat"]
            app.launch()

            let more = app.navigationBars.buttons["More"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 30), "the pushed agent chat opens\n\(app.debugDescription)")

            // The Chief's message sits above the subagent turn: scroll up to it.
            let bubble = app.descendants(matching: .any)["agent-chat.chief-bubble"].firstMatch
            for _ in 0..<14 where !(bubble.exists && bubble.isHittable) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
            }
            XCTAssertTrue(bubble.exists && bubble.isHittable, "the Chief's bubble shows\n\(app.debugDescription)")
            // Said in words, not by colour alone: the bubble names the Chief as its sender.
            XCTAssertTrue(bubble.label.hasPrefix("From Chief"), "the bubble names the Chief: \(bubble.label)")
            // At the right, where a Chief's message sits apart from the agent's rows.
            XCTAssertGreaterThan(bubble.frame.maxX, app.frame.width * 0.85, "the bubble sits at the right")
            attach(app, "chief-bubble-\(name)")
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
