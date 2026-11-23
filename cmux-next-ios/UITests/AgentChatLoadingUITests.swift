import XCTest

/// The user, 2026-11-09: "when I open an existing agent GUI I get shown a new chat UI until the full
/// chat loads ... loading state must be shown if we are still amidst loading." Opens an existing
/// agent chat whose Mac answers 4 s late (`-cmux-mobile-demo slow-history-chat`) and checks every
/// frame until the history lands: the loading state shows, the new-chat prompt ("What should
/// Claude do?", composer "Ask Claude") never does; then the turns show. Before, the chat showed the
/// new-chat screen for those 4 s.
final class AgentChatLoadingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testExistingChatShowsLoadingNotNewChatUntilHistoryLands() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "slow-history-chat"]
        app.launch()
        defer { app.terminate() }

        let loading = app.descendants(matching: .any)["agentChat.loadingHistory"]
        XCTAssertTrue(loading.waitForExistence(timeout: 30), "the existing chat opens on its loading state\n\(app.debugDescription)")
        let newChat = app.staticTexts["What should Claude do?"]
        let reply = app.buttons["Reply to Claude"]
        // Frames across the 4 s the history is held back and after it lands (the evidence video is
        // made of these). The waits only pace the captures.
        var sawRows = false
        for frame in 0..<20 {
            XCTAssertFalse(newChat.exists, "no new-chat prompt at frame \(frame)\n\(app.debugDescription)")
            XCTAssertFalse(app.buttons["Ask Claude"].exists, "no new-chat composer at frame \(frame)")
            attach(app, String(format: "frame-%02d", frame))
            if !loading.exists, reply.exists {
                sawRows = true
            }
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "pace")], timeout: 0.4)
        }
        XCTAssertTrue(sawRows || reply.waitForExistence(timeout: 10), "the history lands\n\(app.debugDescription)")
        XCTAssertFalse(loading.exists, "the loading state leaves once the history is in")
        XCTAssertFalse(newChat.exists, "the chat is not new")
        attach(app, "after-history")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
