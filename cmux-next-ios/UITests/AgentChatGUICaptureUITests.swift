import XCTest

/// Before/after captures of the pushed agent chat (header, transcript, composer dock,
/// jump control, cards) on the shipping app's offline DEBUG chats, in light and dark.
/// Each screenshot is a keepAlways attachment named `agentgui~<state>~<look>`; the
/// fleet's simulator step exports them with their names (`ui-attachments/manifest.json`).
/// A state that cannot be reached fails its own assertion and the run goes on.
final class AgentChatGUICaptureUITests: XCTestCase {
    private enum Look: String, CaseIterable { case dark, light }
    private static let history = ["-cmux-mobile-demo", "disclosure-chat"]
    private static let empty = ["-cmux-mobile-demo", "kbd-chat-empty"]

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRestingStates() {
        for look in Look.allCases {
            scene("history-bottom", look, Self.history) { _ in }
            scene("history-scrolled-up", look, Self.history) { app in
                self.dragDown(app, times: 3)
                self.waitFor(app.buttons["Jump to bottom"].firstMatch, "jump control after scrolling up")
            }
            scene("pending-question", look, ["-cmux-mobile-demo", "kbd-chat"]) { _ in }
            scene("empty-chat", look, Self.empty) { _ in }
            scene("offline-queued", look, ["-cmux-mobile-demo", "offline-send"], settle: 8) { _ in }
        }
    }

    @MainActor
    func testComposerStates() {
        for look in Look.allCases {
            scene("keyboard-draft", look, Self.history) { app in
                self.openComposer(app)
                app.typeText("Run the tests")
            }
            scene("slash-suggestions", look, Self.history) { app in
                self.openComposer(app)
                app.typeText("/")
            }
            scene("long-draft", look, Self.history) { app in
                self.openComposer(app)
                app.typeText("Check the transport layer, then the relay, then the dialer. Summarize what changed in each, list the tests that cover it, and say which of them you ran.")
            }
        }
    }

    @MainActor
    func testTurnStates() {
        for look in Look.allCases {
            scene("running-turn", look, Self.history, after: [("running-turn-later", 4)]) { app in
                self.send(app, "Summarize the transport layer")
                self.waitFor(app.buttons["Stop"].firstMatch, "Stop while the turn runs", timeout: 10)
            }
            scene("first-turn-permission", look, Self.empty, after: [("first-turn-later", 8)]) { app in
                self.send(app, "Plan the release")
            }
        }
    }

    // MARK: Helpers

    @MainActor
    private func scene(_ id: String, _ look: Look, _ args: [String], settle: TimeInterval = 6,
                       after: [(String, TimeInterval)] = [], _ drive: (XCUIApplication) -> Void) {
        XCUIDevice.shared.appearance = look == .dark ? .dark : .light
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore",
                                "-cmuxMobile.settings.appearance", look.rawValue] + args
        app.launch()
        defer { app.terminate() }
        let more = app.navigationBars.buttons["More"].firstMatch
        guard more.waitForExistence(timeout: 30) else {
            XCTFail("\(id) \(look): the agent chat did not open")
            return
        }
        pause(settle)
        drive(app)
        pause(1.2)
        attach(app, "agentgui~\(id)~\(look.rawValue)")
        for (name, delay) in after {
            pause(delay)
            attach(app, "agentgui~\(name)~\(look.rawValue)")
        }
    }

    @MainActor
    private func openComposer(_ app: XCUIApplication) {
        let bar = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
        if bar.waitForExistence(timeout: 5) { bar.tap() }
        let field = app.textViews["chat.composer.field"].firstMatch
        if field.waitForExistence(timeout: 5), !app.keyboards.firstMatch.exists { field.tap() }
        waitFor(app.keyboards.firstMatch, "keyboard up")
    }

    @MainActor
    private func send(_ app: XCUIApplication, _ text: String) {
        openComposer(app)
        app.typeText(text)
        let send = app.buttons["Send"].firstMatch
        waitFor(send, "Send")
        if send.exists { send.tap() }
    }

    @MainActor
    private func dragDown(_ app: XCUIApplication, times: Int) {
        for _ in 0..<times {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                       withVelocity: .slow, thenHoldForDuration: 0)
        }
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 8) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(what) did not appear")
    }

    /// A bounded wait on the run loop for a scene to settle (capture timing only; no
    /// product code waits on it).
    @MainActor
    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: seconds)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
