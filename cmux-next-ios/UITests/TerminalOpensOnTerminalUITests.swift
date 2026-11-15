import XCTest

/// Leo, 2026-11-15, on the iPhone: "for the terminal-gui switch thing can we not have it instantly
/// drop you into the guinview of the terminal in iOS it's such an eyesore rn lmao".
///
/// A terminal tab running Claude Code opens on its terminal; the Chat | Terminal control is there,
/// Terminal lit, and Chat is one tap away and back (the `ws-terminal-agent` demo: mock data, the
/// mock backend's View Only chat). Run with `video` for the before/after recording.
final class TerminalOpensOnTerminalUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    @MainActor
    func testAgentTerminalOpensOnTerminalAndChatIsOneTapAway() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", "ws-terminal-agent"]
        app.launch()
        defer { app.terminate() }

        let chat = app.buttons["tab.terminalChatToggle.chat"].firstMatch
        let terminal = app.buttons["tab.terminalChatToggle.terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "the Chat | Terminal control\n\(app.debugDescription)")
        // Let the page settle as a person would see it on opening.
        Thread.sleep(forTimeInterval: 2.0) // test: hold the opening frame for the recording
        attach(app, "1-opened")
        XCTAssertTrue(terminal.isSelected, "the tab opened on its terminal")
        XCTAssertFalse(chat.isSelected, "not on its chat")

        chat.tap()
        XCTAssertTrue(waitUntil { chat.isSelected }, "one tap shows the chat")
        Thread.sleep(forTimeInterval: 1.5) // test: hold the chat face for the recording
        attach(app, "2-chat")

        terminal.tap()
        XCTAssertTrue(waitUntil { terminal.isSelected }, "one tap back to the terminal")
        Thread.sleep(forTimeInterval: 1.5) // test: hold the terminal face for the recording
        attach(app, "3-terminal-again")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
