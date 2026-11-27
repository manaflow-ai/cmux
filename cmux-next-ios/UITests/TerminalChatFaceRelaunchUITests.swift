import XCTest

/// Each terminal tab's Chat or Terminal face is kept across a real relaunch (Leo, 2026-11-17: "A tab
/// reopens on Chat or Terminal, whichever you left it on."). Mock data with
/// `CMUX_MOBILE_MOCK_TERMINAL_AGENTS=1` lists two workspaces whose terminal runs Claude Code
/// (tab link 16) or Codex (tab link 32); Settings → Terminal → Terminal and Chat Toggle is on. The
/// person shows Claude Code's chat and Codex's terminal (through its chat and back), the app is
/// terminated and launched again, and each tab opens on the face it was left on. The faces go
/// through the file a signed-in account keeps (`KeptTerminalChats`, under the mock account).
///
/// The face is read from the page menu's row: "Show Terminal" on the chat face, "Show Chat" on the
/// terminal. Every step attaches a screenshot (`ui-attachments` in the fleet step's artifact).
final class TerminalChatFaceRelaunchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    static func tabLink(_ number: Int) -> URL {
        URL(string: "cmux://tab/tab_" + String(format: "%032x", number))!
    }

    static let claude = (workspace: "ws-term-claude", link: tabLink(16), title: "claude")
    static let codex = (workspace: "ws-term-codex", link: tabLink(32), title: "codex")
    /// The open tab's title: a terminal's bottom pill is its title, and a tap on it opens the page menu.
    var title = ""

    @MainActor
    func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchEnvironment["CMUX_MOBILE_MOCK_TERMINAL_AGENTS"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "home", "-cmux-mobile-no-restore",
                                "-cmuxMobile.settings.terminalChatToggle", "YES"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "shell\n\(app.debugDescription)")
        return app
    }

    @MainActor
    func open(_ app: XCUIApplication, _ target: (workspace: String, link: URL, title: String)) {
        title = target.title
        app.open(target.link)
        let page = app.descendants(matching: .any)["workspace.\(target.workspace)"]
        XCTAssertTrue(page.waitForExistence(timeout: 15), "workspace \(target.workspace)\n\(app.debugDescription)")
    }

    /// The page menu's Show Chat / Show Terminal row; the menu stays open. A terminal's bottom pill
    /// shows only its title (no page-menu glyph): a tap on the title opens the menu.
    @MainActor
    func faceRow(_ app: XCUIApplication) -> XCUIElement? {
        let glyph = app.buttons["Page Menu"].firstMatch
        let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), ")).firstMatch
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Show Chat' OR label BEGINSWITH 'Show Terminal'")).firstMatch
        // A collapsed pill takes its first tap to expand.
        for _ in 0..<2 {
            if pill.waitForExistence(timeout: 10), pill.isHittable {
                pill.tap()
            } else if glyph.exists, glyph.isHittable {
                glyph.tap()
            }
            if row.waitForExistence(timeout: 5) { return row }
        }
        attach(app, "no-face-row-\(title)")
        return nil
    }

    /// The face the open tab shows ("chat" or "terminal"), read from the page menu, which closes again.
    @MainActor
    func face(_ app: XCUIApplication) -> String? {
        guard let row = faceRow(app) else { return nil }
        let face = row.label.hasPrefix("Show Terminal") ? "chat" : "terminal"
        dismiss(app)
        _ = row.waitForNonExistence(timeout: 5)
        return face
    }

    /// Closes the open page menu (or the keyboard) without a tap on the page: a tap on the terminal
    /// lands on its text, and a path there opens Files and Links over the page.
    @MainActor
    func dismiss(_ app: XCUIApplication) {
        // The status bar's strip: the menu's full-screen dismiss region covers it, the page has no text there.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        let files = app.staticTexts["Files and Links"].firstMatch
        if files.exists { app.buttons["Done"].firstMatch.tap() }
    }

    /// Waits until the open tab shows `wanted` (the kept face lands once the file is read).
    @MainActor
    func expectFace(_ app: XCUIApplication, _ wanted: String, _ step: String) {
        var seen: String?
        for _ in 0..<8 {
            seen = face(app)
            if seen == wanted { break }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        attach(app, step)
        XCTAssertEqual(seen, wanted, "\(step): the tab shows \(seen ?? "no face row")\n\(app.debugDescription)")
    }

    /// A tap on the page menu's row that shows `face`.
    @MainActor
    func show(_ app: XCUIApplication, _ face: String) {
        let row = faceRow(app)
        let rowTitle = face == "chat" ? "Show Chat" : "Show Terminal"
        XCTAssertEqual(row?.label.hasPrefix(rowTitle), true, "no \(rowTitle) row\n\(app.debugDescription)")
        row?.tap()
    }

    @MainActor
    func testEachTabReopensOnTheFaceItWasLeftOn() throws {
        var app = launch()

        // Claude Code: opens on its terminal; the person shows its chat.
        open(app, Self.claude)
        expectFace(app, "terminal", "01-claude-opens-on-terminal")
        show(app, "chat")
        expectFace(app, "chat", "02-before-relaunch-claude-on-chat")

        // Codex: the person shows its chat, then its terminal again.
        open(app, Self.codex)
        show(app, "chat")
        expectFace(app, "chat", "03-codex-on-chat")
        show(app, "terminal")
        expectFace(app, "terminal", "04-before-relaunch-codex-on-terminal")

        // The write is one main-actor turn and a utility-queue write; give it time, then relaunch.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.terminate()
        app = launch()

        open(app, Self.claude)
        expectFace(app, "chat", "05-after-relaunch-claude-on-chat")
        open(app, Self.codex)
        expectFace(app, "terminal", "06-after-relaunch-codex-on-terminal")
    }

    /// Leo, 2026-11-16: "it's not usable like the regular gui". A terminal's Chat face has the
    /// regular chat's composer, and a prompt sent there is typed into the terminal that runs the
    /// session (#44137). On mock data the terminal is the DEBUG mock shell, which echoes what it is
    /// typed: the Terminal face then shows the line.
    @MainActor
    func testAPromptOnTheChatFaceIsTypedIntoItsTerminal() throws {
        let app = launch()
        open(app, Self.claude)
        expectFace(app, "terminal", "11-claude-opens-on-terminal")
        show(app, "chat")
        expectFace(app, "chat", "12-claude-on-chat")

        // The regular chat's composer, under the View Only chat.
        let bar = app.buttons["Reply to Claude"].firstMatch
        let field = app.textViews["chat.composer.field"].firstMatch
        if !field.waitForExistence(timeout: 5) {
            XCTAssertTrue(bar.waitForExistence(timeout: 15), "the Chat face shows a composer\n\(app.debugDescription)")
            bar.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the composer opens\n\(app.debugDescription)")
        attach(app, "13-chat-face-composer")
        for _ in 0..<5 where !((field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false) {
            field.tap()
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"),
                                                                 object: field)], timeout: 2)
        }
        field.typeText("echo sent-from-the-chat-face")
        attach(app, "14-chat-face-typed")
        app.buttons["Send"].firstMatch.tap()

        // Taken by the terminal: no "Not sent" notice, and the draft does not come back.
        let refused = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Not sent'")).firstMatch
        XCTAssertFalse(refused.waitForExistence(timeout: 3), "the terminal took the prompt\n\(app.debugDescription)")
        attach(app, "15-chat-face-sent")

        // The terminal ran it: its face shows the mock shell's echo.
        dismiss(app)
        show(app, "terminal")
        expectFace(app, "terminal", "16-terminal-face-shows-the-prompt")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        print("CMUX_MOBILE_UI_STEP \(name)")
    }
}
