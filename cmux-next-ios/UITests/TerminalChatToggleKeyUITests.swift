import XCTest

/// The terminal and chat toggle as the person uses it (Leo, 2026-11-22: "dont have it read only.
/// just do it properly."): on a terminal running Claude Code, Show Chat flips to the chat face, the
/// chat face's composer takes a prompt, and Show Terminal flips back. One test per placement
/// (`CMUX_TERMINAL_CHAT_TOGGLE`, DEBUG only): pinned beside the composer key (the default), the key
/// row's first key, or beside the Tabs button. Mock data with `CMUX_MOBILE_MOCK_TERMINAL_AGENTS=1`;
/// Settings → Terminal → Terminal and Chat Toggle is on. Every step attaches a screenshot, and the
/// fleet step's `video` records the run.
final class TerminalChatToggleKeyUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    static let claudeLink = URL(string: "cmux://tab/tab_" + String(format: "%032x", 16))!

    @MainActor
    func launch(placement: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_MOCK_TERMINAL_AGENTS"] = "1"
        app.launchEnvironment["CMUX_TERMINAL_CHAT_TOGGLE"] = placement
        app.launchArguments += ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore",
                                "-cmuxMobile.settings.terminalChatToggle", "YES"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "shell\n\(app.debugDescription)")
        app.open(Self.claudeLink)
        let page = app.descendants(matching: .any)["workspace.ws-term-claude"]
        XCTAssertTrue(page.waitForExistence(timeout: 15), "workspace\n\(app.debugDescription)")
        return app
    }

    /// The toggle on the face showing now: a key (`terminal.key.showChat`, `terminal.key.showTerminal`)
    /// or, for the toolbar placement, the capsule's trailing button.
    @MainActor
    func toggle(_ app: XCUIApplication, toolbar: Bool, showing face: String) -> XCUIElement {
        if toolbar {
            return app.buttons.matching(identifier: "tabskit.trailingAction").firstMatch
        }
        return app.buttons[face == "terminal" ? "terminal.key.showChat" : "terminal.key.showTerminal"].firstMatch
    }

    @MainActor
    func run(placement: String) {
        let app = launch(placement: placement)
        let toolbar = placement == "toolbar"
        attach(app, "\(placement)-01-terminal")

        let showChat = toggle(app, toolbar: toolbar, showing: "terminal")
        XCTAssertTrue(showChat.waitForExistence(timeout: 15), "\(placement): no Show Chat\n\(app.debugDescription)")
        XCTAssertEqual(showChat.label.hasPrefix("Show Chat") || showChat.label.hasPrefix("Chat"), true, showChat.label)
        showChat.tap()

        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "\(placement): no composer on the chat face\n\(app.debugDescription)")
        attach(app, "\(placement)-02-chat")
        field.tap()
        field.typeText("Run the tests again please")
        attach(app, "\(placement)-03-typed")

        let showTerminal = toggle(app, toolbar: toolbar, showing: "chat")
        XCTAssertTrue(showTerminal.waitForExistence(timeout: 10), "\(placement): no Show Terminal\n\(app.debugDescription)")
        showTerminal.tap()
        let back = toggle(app, toolbar: toolbar, showing: "terminal")
        XCTAssertTrue(back.waitForExistence(timeout: 15), "\(placement): Show Chat did not come back\n\(app.debugDescription)")
        attach(app, "\(placement)-04-terminal-again")
    }

    @MainActor func testPinnedBesideTheComposerKey() { run(placement: "pinned") }
    @MainActor func testFirstKeyOfTheKeyRow() { run(placement: "keybar-first") }
    @MainActor func testBesideTheTabsButton() { run(placement: "toolbar") }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        print("CMUX_MOBILE_UI_STEP \(name)")
    }
}
