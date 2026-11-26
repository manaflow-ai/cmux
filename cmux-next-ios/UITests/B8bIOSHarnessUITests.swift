import XCTest

/// B8b's shared-view fixture runs the actual iOS Feed and agent-chat screens in
/// a DEBUG host. The annotation keeps these captures distinct from native macOS
/// runtime evidence while AppKit styling remains unavailable on the Linux route.
final class B8bIOSHarnessUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testSharedViewsRenderInIOSHarness() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-b8b-harness"]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(
            app.staticTexts["b8b.harness.annotation"].waitForExistence(timeout: 30),
            "the DEBUG iOS host annotation is visible\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.navigationBars["Feed"].waitForExistence(timeout: 30),
                      "the shared FeedScreen is hosted\n\(app.debugDescription)")
        attach(app, "b8b-ios-feed")

        let chatTab = app.tabBars.buttons["Agent chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 10),
                      "the agent-chat harness tab is visible\n\(app.debugDescription)")
        chatTab.tap()
        XCTAssertTrue(app.navigationBars.buttons["More"].waitForExistence(timeout: 30),
                      "the shared AgentChatScreen is hosted\n\(app.debugDescription)")
        attach(app, "b8b-ios-agent-chat")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
