import XCTest

/// In a workspace's agent tab the chat composer's field carried the workspace
/// page's identifier (`workspace.ws-cmux`) instead of its own
/// (`chat.composer.field`): the page's `.accessibilityIdentifier` was applied to
/// every element inside it. The field keeps its own identifier there, as it
/// does in the pushed agent chat, and the page is still found by its own.
final class ComposerFieldIdentifierUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testTabComposerFieldKeepsItsIdentifier() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "kbd-tab"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["workspace.ws-cmux"].waitForExistence(timeout: 30),
                      "the workspace page keeps its identifier")
        let byPlaceholder = app.textViews.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
        if !byPlaceholder.waitForExistence(timeout: 15) {
            // The collapsed capsule opens the field.
            let capsule = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
            if capsule.waitForExistence(timeout: 5) { capsule.tap() }
        }
        XCTAssertTrue(byPlaceholder.waitForExistence(timeout: 30), "the tab's composer field is shown\n\(app.debugDescription)")
        XCTAssertEqual(byPlaceholder.identifier, "chat.composer.field", "the tab's composer field has its own identifier")
        XCTAssertTrue(app.textViews["chat.composer.field"].exists, "chat.composer.field is found in the tab")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "tab-composer-field"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
