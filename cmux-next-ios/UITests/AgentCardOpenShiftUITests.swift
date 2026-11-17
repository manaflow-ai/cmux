import XCTest

/// Leo (2026-11-17): "Preview causes layout shift bc preview vs display with composer is
/// different". Opens ws-cmux from the Workspaces list, opens the tab grid, and opens the Claude
/// tab's card, twice: first a tab not shown yet in this launch (its composer never measured),
/// then again after it was shown. Screenshots of the grid and of the page's first frames after
/// the tap, for the video and the PR; the per-row shift numbers come from
/// `AgentCardOpenGeometryTests` (kit tests), which measure the same layout by row id.
final class AgentCardOpenShiftUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testOpeningAnAgentCardFromTheGrid() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore", "-cmux-mobile-tab", "workspaces"]
        app.launch()
        defer { app.terminate() }

        let row = app.buttons["workspace.row.ws-cmux"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the ws-cmux row\n\(app.debugDescription)")
        row.tap()
        pause(2.0)
        attach(app, "0-workspace-opened")

        for round in 1 ... 2 {
            let tabs = app.buttons["Tabs"].firstMatch
            XCTAssertTrue(tabs.waitForExistence(timeout: 15), "the Tabs button")
            tabs.tap()
            // The grid rests: its agent cards are drawn as pictures.
            pause(3.0)
            attach(app, "\(round)-a-grid")
            let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Claude' AND label ENDSWITH ', tab'")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10), "the Claude card\n\(app.debugDescription)")
            card.tap()
            // The zoom and the first frames of the page, then at rest.
            for index in 0 ..< 8 {
                attach(app, "\(round)-b-open-\(index)")
                pause(0.12)
            }
            pause(1.5)
            attach(app, "\(round)-c-rest")
            XCTAssertTrue(app.buttons["Reply to Claude"].firstMatch.waitForExistence(timeout: 10), "the Claude page's composer")
        }
    }

    @MainActor
    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
