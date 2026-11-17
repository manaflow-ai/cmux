import XCTest

/// A plain tap on New Workspace opens the new workspace on an agent chat, not a terminal
/// (Aziz, 2026-11-17). The terminal stays one item away (long press › New Terminal
/// Workspace), and a Mac that can't start an agent from the phone still gets a terminal.
/// Mock data: the Mac Studio's workspaces are open in project folders, so the tap's chat
/// starts in the most recent one.
final class NewWorkspaceDefaultAgentUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testPlainTapOpensAnAgentChat() {
        let app = launch()
        tapNewWorkspace(app)
        expectPage(app, chat: true, "a plain tap opens the new workspace on an agent chat")
        attach(app, "1-plain-tap-agent-chat")
    }

    @MainActor
    func testMenuStillMakesATerminalWorkspace() {
        let app = launch()
        let new = app.descendants(matching: .any)["workspaces.new"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 30), "New Workspace button\n\(app.debugDescription)")
        new.press(forDuration: 1.0)
        let terminal = app.descendants(matching: .any)["workspaces.newTerminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), "New Terminal Workspace in the menu\n\(app.debugDescription)")
        attach(app, "2-menu-terminal-item")
        terminal.tap()
        expectPage(app, chat: false, "New Terminal Workspace opens the new workspace on a terminal")
        attach(app, "3-menu-terminal-workspace")
    }

    @MainActor
    func testPlainTapIsATerminalWhenTheMacStartsNoAgents() {
        let app = launch(["-cmux-mobile-no-agents"])
        tapNewWorkspace(app)
        expectPage(app, chat: false, "with no agents a plain tap still opens a terminal")
        attach(app, "4-no-agents-terminal")
    }

    /// The Mac refuses the chat (here: its folder is no longer open there): the refusal shows
    /// in its words and the placeholder row goes, so the list is back as it was.
    @MainActor
    func testRefusedChatSaysWhyAndLeavesNoRow() {
        let app = launch(["-cmux-mobile-refuse-next-create"])
        tapNewWorkspace(app)
        let why = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Agent chats start in a folder")).firstMatch
        XCTAssertTrue(why.waitForExistence(timeout: 20), "the refusal is shown\n\(app.debugDescription)")
        attach(app, "5-refused-toast")
        let placeholder = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.row.new-'")).firstMatch
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: placeholder)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 15), .completed, "the refused placeholder row is removed\n\(app.debugDescription)")
        attach(app, "6-refused-list")
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore"] + extra
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        XCTAssertTrue(app.buttons["workspace.row.ws-cmux"].waitForExistence(timeout: 30), "workspace list\n\(app.debugDescription)")
        attach(app, "0-list")
        return app
    }

    @MainActor
    private func tapNewWorkspace(_ app: XCUIApplication) {
        let new = app.descendants(matching: .any)["workspaces.new"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 30), "New Workspace button\n\(app.debugDescription)")
        new.tap()
    }

    /// The pushed workspace page shows a chat (an `agentChat.` element) or a terminal (a
    /// `terminal.` element), and not the other.
    @MainActor
    private func expectPage(_ app: XCUIApplication, chat: Bool, _ message: String) {
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'workspace.new-'")).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20), "the new workspace was pushed\n\(app.debugDescription)")
        let wanted = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", chat ? "agentChat." : "terminal.")).firstMatch
        let other = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", chat ? "terminal." : "agentChat.")).firstMatch
        if !wanted.waitForExistence(timeout: 20) {
            attach(app, "FAIL-\(message)")
            XCTFail("\(message)\n\(app.debugDescription)")
        }
        XCTAssertFalse(other.exists && other.isHittable, "\(message): the other kind is not on screen\n\(app.debugDescription)")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
