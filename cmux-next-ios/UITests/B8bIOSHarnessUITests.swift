import CryptoKit
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
        let feedRow = app.tables["feed.list"].cells["feed.row.f-question"]
        XCTAssertTrue(feedRow.waitForExistence(timeout: 30), "the mock Feed event rendered")
        XCTAssertTrue(feedRow.isHittable, "the Feed event is on screen")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Nightly")).firstMatch.waitForExistence(timeout: 10),
                      "the shared question content rendered, not just Feed chrome")
        attach(app, "b8b-ios-feed")

        let chatTab = app.tabBars.buttons["Agent chat"]
        XCTAssertTrue(chatTab.waitForExistence(timeout: 10),
                      "the agent-chat harness tab is visible\n\(app.debugDescription)")
        chatTab.tap()
        XCTAssertTrue(app.navigationBars.buttons["More"].waitForExistence(timeout: 30),
                      "the shared AgentChatScreen is hosted\n\(app.debugDescription)")
        let history = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "The transport switch holds up")
        ).firstMatch
        // The shared chat opens at the end of history. Reveal the report text
        // using the real transcript, rather than accepting only its toolbar.
        for _ in 0..<8 {
            if history.waitForExistence(timeout: 2), history.isHittable { break }
            app.swipeDown()
        }
        XCTAssertTrue(history.exists && history.isHittable,
                      "the mock transcript report is visible\n\(app.debugDescription)")
        attach(app, "b8b-ios-agent-chat")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // agent-sim currently acknowledges XCTest attachments without saving them.
        // Export the same real screenshot through its existing runner console.
        // Keep each line below the runner's 400-character forwarding limit.
        let png = screenshot.pngRepresentation
        guard png.count <= 8 * 1024 * 1024 else {
            XCTFail("harness PNG exceeds the bounded console export")
            return
        }
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let encoded = Array(png.base64EncodedString().utf8)
        print("B8B_PNG_BEGIN \(name) \(digest) \(encoded.count)")
        for offset in stride(from: 0, to: encoded.count, by: 240) {
            let chunk = String(decoding: encoded[offset..<min(offset + 240, encoded.count)], as: UTF8.self)
            print("B8B_PNG_CHUNK \(name) \(offset) \(chunk)")
        }
        print("B8B_PNG_END \(name)")
    }
}
