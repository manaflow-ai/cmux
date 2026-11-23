import XCTest

/// The user, 2026-11-11: "disable the send with effect feature in chief gui,
/// it's irrelevant." Chief's Send has no long press: holding it no longer opens
/// Messages' "Send with effect" picker (Bubble/Screen, Slam, Loud, Gentle,
/// Invisible Ink); releasing it sends the draft like a tap. A plain tap still
/// sends. Real touches on the mock Chief, in light and dark, at the default
/// text size and at Accessibility XXXL. Before, the hold opened the picker and
/// held the draft in it.
final class ChiefSendWithoutEffectUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor func testLight() { run(.light, largeText: false) }
    @MainActor func testDark() { run(.dark, largeText: false) }
    @MainActor func testLightLargeText() { run(.light, largeText: true) }
    @MainActor func testDarkLargeText() { run(.dark, largeText: true) }

    @MainActor
    private func run(_ appearance: XCUIDevice.Appearance, largeText: Bool) {
        XCUIDevice.shared.appearance = appearance
        let look = (appearance == .dark ? "dark" : "light") + (largeText ? "-axxxl" : "")
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES",
                                "-cmuxMobile.settings.appearance", appearance == .dark ? "dark" : "light",
                                "-cmux-mobile-demo", "chief-open"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        defer { app.terminate() }

        let field = app.textViews["conversation.composer.text"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "Chief's composer\n\(app.debugDescription)")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8), "the keyboard is up")
        field.typeText("Ship it")
        let send = app.buttons["conversation.composer.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "Send shows with a draft")
        attach(app, "1-composer-\(look)")

        // A long press on Send: past the package's 0.4 s effect press.
        send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.2)
        let picker = app.descendants(matching: .any)["conversation.effects.cancel"].firstMatch
        XCTAssertFalse(picker.waitForExistence(timeout: 1.5), "no Send with effect picker\n\(app.debugDescription)")
        XCTAssertFalse(app.descendants(matching: .any)["conversation.effects.mode"].exists, "no Bubble/Screen tabs")
        XCTAssertTrue(sent("Ship it", from: field), "the held Send sent the draft\n\(app.debugDescription)")
        attach(app, "2-long-press-sent-\(look)")

        // A plain tap still sends.
        field.typeText("Status?")
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        XCTAssertTrue(sent("Status?", from: field), "a tap on Send sends\n\(app.debugDescription)")
        XCTAssertFalse(picker.exists, "no picker after a tap either")
        attach(app, "3-tap-sent-\(look)")
    }

    /// The draft left the composer: sent. (Its bubble can be above the screen at once: at
    /// Accessibility XXXL on a small iPhone the mock Chief's reply fills the transcript, and
    /// rows off screen are not in the tree.) Before, the picker held the draft in the field.
    @MainActor
    private func sent(_ text: String, from field: XCUIElement) -> Bool {
        let gone = NSPredicate(format: "NOT (value CONTAINS %@)", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: field)], timeout: 5) == .completed
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
