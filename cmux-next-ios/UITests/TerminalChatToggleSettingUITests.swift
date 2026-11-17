import XCTest

/// Settings → Terminal → Terminal and Chat Toggle (off by default): a tab's page
/// menu offers Show Chat / Show Terminal only with the setting on, and only where
/// both faces work. The mock workspace has a GUI-only Claude chat (`t-claude`: no
/// terminal runs its session) and a plain shell (`t-zsh`).
final class TerminalChatToggleSettingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    /// Setting off (the default): neither the chat nor the terminal offers the toggle.
    @MainActor
    func testToggleOffOffersNoRow() throws {
        let chat = launch(demo: "kbd-tab", toggle: nil)
        openPageMenu(chat, title: "Claude")
        attach(chat, "off-1-claude-chat-menu")
        assertNoToggleRow(chat, "setting off, GUI chat")
        chat.terminate()

        let shell = launch(demo: "ws-terminal-idle", toggle: nil)
        openPageMenu(shell, title: "zsh")
        attach(shell, "off-2-terminal-menu")
        assertNoToggleRow(shell, "setting off, terminal")
    }

    /// Setting on: a chat no terminal runs still offers no Show Terminal.
    @MainActor
    func testToggleOnGuiOnlyChatOffersNoShowTerminal() throws {
        let app = launch(demo: "kbd-tab", toggle: true)
        openPageMenu(app, title: "Claude")
        attach(app, "on-1-claude-chat-menu")
        assertNoToggleRow(app, "setting on, GUI-only chat")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No terminal runs")).firstMatch.exists,
                       "no 'No terminal runs this chat' notice")
    }

    /// Setting off: a Claude Code terminal (its session known, a chat the Mac can open) offers no
    /// Show Chat (`-cmux-mobile-demo ws-terminal-chat`).
    @MainActor
    func testToggleOffClaudeTerminalOffersNoShowChat() throws {
        let app = launch(demo: "ws-terminal-chat", toggle: nil)
        openPageMenu(app, title: "claude")
        attach(app, "off-3-claude-terminal-menu")
        assertNoToggleRow(app, "setting off, Claude Code terminal")
    }

    /// Setting on: a Claude Code terminal swaps to the View Only chat of its session and back,
    /// from its page menu, in place.
    @MainActor
    func testToggleOnClaudeTerminalSwapsBothWays() throws {
        let app = launch(demo: "ws-terminal-chat", toggle: true)
        let field = app.textViews["terminal.composer.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "opens on its terminal\n\(app.debugDescription)")
        attach(app, "swap-1-terminal")

        openPageMenu(app, title: "claude")
        let showChat = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show Chat")).firstMatch
        XCTAssertTrue(showChat.waitForExistence(timeout: 5), "Show Chat in the page menu\n\(app.debugDescription)")
        attach(app, "swap-2-menu-show-chat")
        showChat.tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "the terminal face is gone\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 1.0)
        attach(app, "swap-3-chat")

        openPageMenu(app, title: "claude")
        let showTerminal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show Terminal")).firstMatch
        XCTAssertTrue(showTerminal.waitForExistence(timeout: 5), "Show Terminal in the chat's page menu\n\(app.debugDescription)")
        attach(app, "swap-4-menu-show-terminal")
        showTerminal.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5), "back on its terminal\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 0.5)
        attach(app, "swap-5-terminal-again")
    }

    /// The setting itself: Settings → Terminal shows the switch, off by default.
    @MainActor
    func testSettingIsOffByDefault() throws {
        let app = launch(demo: "settings", toggle: nil, waitForPageMenu: false)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Terminal")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Settings → Terminal\n\(app.debugDescription)")
        row.tap()
        let toggle = app.switches["settings.terminalChatToggle"]
        if !toggle.waitForExistence(timeout: 5) { app.swipeUp() }
        if toggle.waitForExistence(timeout: 20) {
            attach(app, "settings-terminal")
            XCTAssertEqual(toggle.value as? String, "0", "Terminal and Chat Toggle is off by default")
        } else {
            attach(app, "settings-terminal-missing")
            XCTFail("no Terminal and Chat Toggle switch\n\(app.debugDescription)")
        }
    }

    // MARK: Helpers

    @MainActor
    private func launch(demo: String, toggle: Bool?, waitForPageMenu: Bool = true) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-demo", demo]
        if let toggle { app.launchArguments += ["-cmuxMobile.settings.terminalChatToggle", toggle ? "YES" : "NO"] }
        app.launch()
        if waitForPageMenu {
            XCTAssertTrue(app.buttons["Page Menu"].firstMatch.waitForExistence(timeout: 30), "page toolbar\n\(app.debugDescription)")
            Thread.sleep(forTimeInterval: 1.5)
        }
        return app
    }

    /// The page menu opens from its glyph, or from the title pill where the glyph is hidden.
    @MainActor
    private func openPageMenu(_ app: XCUIApplication, title: String) {
        // The title pill sits at the toolbar's center, on the Page Menu glyph's row; a tap on it
        // opens the page menu (the glyph itself is hidden on a terminal's title-only pill).
        let glyph = app.buttons["Page Menu"].firstMatch
        let window = app.windows.firstMatch.frame
        let row = glyph.exists ? glyph.frame.midY : window.maxY - 56
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.midX, dy: row)).tap()
        let marker = NSPredicate(format: "label BEGINSWITH 'Copy Tab' OR label BEGINSWITH 'Files and Links'")
        XCTAssertTrue(app.buttons.matching(marker).firstMatch.waitForExistence(timeout: 5),
                      "the page menu opened (\(title))\n\(app.debugDescription)")
        Thread.sleep(forTimeInterval: 0.5)
    }

    @MainActor
    private func assertNoToggleRow(_ app: XCUIApplication, _ step: String) {
        for label in ["Show Terminal", "Show Chat"] {
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch.exists,
                           "\(step): the page menu offers \(label)")
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
