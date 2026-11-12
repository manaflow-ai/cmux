import XCTest

/// A workspace opens on its layout's leftmost, topmost pane's active tab (user 2026-11-11).
/// The `workspace-open-top-left` demo lays ws-cmux out as zsh | (Claude, docs), with the right
/// pane focused on the Mac and docs the last tab used on this phone, opens it, switches to
/// docs, leaves and opens it again. Both opens show zsh (the terminal's key row), never the
/// Mac's focused Claude tab nor the docs tab used last. Before the change the first open
/// showed docs and the reopen showed docs again.
final class WorkspaceOpenTopLeftUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testWorkspaceOpensOnTheTopLeftPanesActiveTab() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-demo", "workspace-open-top-left"]
        app.launch()
        defer { app.terminate() }

        let terminal = app.buttons["terminal.key.control"].firstMatch
        let claude = app.buttons["Reply to Claude"].firstMatch

        expect(terminal, "exists == true AND hittable == true", timeout: 20, "first open: the zsh tab (top-left pane) is on screen")
        XCTAssertFalse(claude.exists && claude.isHittable, "first open: not the Mac's focused Claude tab")
        attach(app, "1-first-open-zsh")

        // The demo switches to docs, then leaves the workspace.
        expect(terminal, "hittable == false OR exists == false", timeout: 15, "the demo switched to docs")
        attach(app, "2-switched-to-docs")
        expect(app.descendants(matching: .any)["workspace.ws-cmux"], "exists == false", timeout: 15, "left the workspace")
        attach(app, "3-workspaces-list")

        // Reopened: zsh again, not docs (the last tab used here).
        expect(terminal, "exists == true AND hittable == true", timeout: 20, "reopen: the zsh tab again")
        XCTAssertFalse(claude.exists && claude.isHittable, "reopen: not the Claude tab")
        attach(app, "4-reopen-zsh")
    }

    @MainActor
    private func expect(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval, _ message: String) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        let app = XCUIApplication()
        if XCTWaiter().wait(for: [expectation], timeout: timeout) != .completed {
            attach(app, "FAIL-\(message)")
            XCTFail("\(message)\n\(app.debugDescription)")
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
