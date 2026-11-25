import XCTest

/// Leo, 2026-11-24: "the 'updating' is a bit meh ... they dont need to know that it's updating
/// before they KNOW it's updating". Every place that said "Updating…" over rows the phone already
/// had, held in that state by a demo (mock data, no private connection), past the delay each used
/// (1.5 s for the subtitles, 10 s for the chips): nothing may say it updates. Run with the fleet
/// step's `video` for the launch → Workspaces → chat recording; the gallery shots are the
/// variants it was picked from (`-cmux-mobile-recovery-gallery quiet-*`).
final class QuietUpdatingUITests: XCTestCase {
    override func setUp() {
        // Every shot is taken even when one place still says it: the before run's evidence.
        continueAfterFailure = true
    }

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES", "-cmux-mobile-no-restore"] + arguments
        app.launch()
        return app
    }

    private func updating(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Updating")).firstMatch
    }

    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "pace")], timeout: seconds)
    }

    /// Launch on the Workspaces list while its team refreshes over the cached rows, then open a
    /// workspace's agent chat while it catches up with its Mac: the rows and turns show, nothing
    /// says "Updating".
    @MainActor
    func test1LaunchWorkspacesThenChatSayNothing() {
        let app = launch(["-cmux-mobile-demo", "retry-workspaces-updating"])
        defer { app.terminate() }
        let row = app.buttons["workspace.row.ws-cmux"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the cached rows\n\(app.debugDescription)")
        pause(3)
        attach(app, "1-workspaces-refreshing-3s")
        XCTAssertFalse(updating(app).exists, "the Workspaces list says nothing past 1.5 s\n\(app.debugDescription)")
        row.tap()
        let reply = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reply to'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "the chat's composer\n\(app.debugDescription)")
        attach(app, "2-chat-opened")
        pause(12)
        attach(app, "3-chat-catching-up-12s")
        XCTAssertFalse(updating(app).exists, "the chat says nothing past 10 s\n\(app.debugDescription)")
    }

    /// Home with the conversations this phone kept, the Mac's own list not in yet.
    @MainActor
    func test2HomeKeptRowsSayNothing() {
        let app = launch(["-cmux-mobile-demo", "retry-home-updating"])
        defer { app.terminate() }
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Conversation 1")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the kept rows\n\(app.debugDescription)")
        pause(12)
        attach(app, "4-home-kept-12s")
        XCTAssertFalse(updating(app).exists, "Home says nothing past 10 s\n\(app.debugDescription)")
    }

    /// The before and the three variants, one shot each.
    @MainActor
    func test3Gallery() {
        for variant in ["before", "a", "b", "c"] {
            let app = launch(["-cmux-mobile-recovery-gallery", "quiet-\(variant)", "-cmux-mobile-gallery-appearance", "light"])
            XCTAssertTrue(app.descendants(matching: .any)["recoveryGallery.quiet.\(variant)"].waitForExistence(timeout: 30),
                          "gallery \(variant)\n\(app.debugDescription)")
            pause(1)
            attach(app, "gallery-\(variant)")
            app.terminate()
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
