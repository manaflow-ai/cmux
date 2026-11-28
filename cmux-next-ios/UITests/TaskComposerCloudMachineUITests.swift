import XCTest

/// New Task on a Cloud machine, end to end on mock data with real taps (#54742): the Runs on
/// pill lists the Mac and the Cloud machine; picking the Cloud machine and Start opens that
/// machine's Cloud chats page; picking the Mac puts the Mac's agents back; and the next New Task
/// keeps the Cloud machine, so it is two taps (New Task, Start) plus the prompt.
/// `-cmux-mobile-mock-cloud-machine` (DEBUG) has the mock Mac list one Cloud machine, "Build box".
final class TaskComposerCloudMachineUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testRunsOnACloudMachineAndStartOpensItsChat() {
        let app = launch()

        // Tap 1: New Task.
        openComposer(app)
        let place = any(app, "taskComposer.place")
        XCTAssertTrue(place.waitForExistence(timeout: 10), "the Runs on pill shows once a Cloud machine is listed\n\(app.debugDescription)")
        attach(app, "1-new-task-runs-on-pill")

        // Runs on: the Mac, then back to the Cloud machine.
        pick(app, place, labelContains: "Mac Studio")
        XCTAssertTrue(wait { (place.value as? String)?.contains("Mac Studio") == true }, "Runs on reads the Mac, got \(String(describing: place.value))")
        XCTAssertTrue(any(app, "taskComposer.agents").waitForExistence(timeout: 5), "on the Mac, the Mac's agents pill is back")
        XCTAssertFalse(any(app, "taskComposer.agents.cloud").exists, "on the Mac, no Cloud agent pill")
        attach(app, "2-runs-on-mac")

        pick(app, place, labelContains: "Build box")
        XCTAssertTrue(wait { (place.value as? String) == "Build box" }, "Runs on reads the Cloud machine, got \(String(describing: place.value))")
        XCTAssertTrue(any(app, "taskComposer.agents.cloud").waitForExistence(timeout: 5), "on the Cloud machine the agent is Claude")
        attach(app, "3-runs-on-cloud-machine")

        type(app, "Fix the flaky upload test")
        let start = app.buttons["taskComposer.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5) && start.isEnabled, "Start is on with a prompt\n\(app.debugDescription)")
        XCTAssertEqual(start.value as? String, "on Build box")
        attach(app, "4-ready-to-start-on-cloud")

        // Start: the sheet closes and the machine's Cloud chats page opens.
        start.tap()
        XCTAssertTrue(any(app, "taskComposer.prompt").waitForNonExistence(timeout: 5), "the composer closes at once")
        XCTAssertTrue(app.navigationBars["Build box"].waitForExistence(timeout: 10), "Start opens the Cloud machine's page\n\(app.debugDescription)")
        attach(app, "5-started-cloud-machine-page")

        // The next task: the Cloud machine is remembered, so New Task then Start.
        closeCloudChats(app)
        openComposer(app)
        XCTAssertTrue(wait { (any(app, "taskComposer.place").value as? String) == "Build box" },
                      "the next New Task keeps the Cloud machine\n\(app.debugDescription)")
        attach(app, "6-next-task-remembers-cloud-machine")
        type(app, "Open a PR for it")
        let again = app.buttons["taskComposer.start"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 5) && again.isEnabled)
        again.tap()
        XCTAssertTrue(app.navigationBars["Build box"].waitForExistence(timeout: 10), "the second Start opens the Cloud machine's page\n\(app.debugDescription)")
        attach(app, "7-second-task-two-taps")
    }

    // MARK: - Steps

    @MainActor
    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmux-mobile-tab", "workspaces", "-cmux-mobile-no-restore", "-cmux-mobile-fresh-task-setup",
                                "-cmux-mobile-mock-cloud-machine"]
        app.launch()
        let choose = app.scrollViews["setup.teams.choose"]
        if choose.waitForExistence(timeout: 10) { app.buttons["Manaflow"].tap() }
        XCTAssertTrue(any(app, "workspaces.newTask").waitForExistence(timeout: 30), "the New Task button\n\(app.debugDescription)")
        return app
    }

    @MainActor
    private func openComposer(_ app: XCUIApplication) {
        let new = any(app, "workspaces.newTask")
        XCTAssertTrue(new.waitForExistence(timeout: 15), "the New Task button\n\(app.debugDescription)")
        new.tap()
        XCTAssertTrue(any(app, "taskComposer.prompt").waitForExistence(timeout: 10), "the composer opens\n\(app.debugDescription)")
        // The system keyboard's one-time tip covers the sheet.
        let next = app.buttons["Continue"].firstMatch
        if next.waitForExistence(timeout: 1.5), next.isHittable { next.tap() }
    }

    /// Opens the Runs on menu and taps the item whose label contains `text`.
    @MainActor
    private func pick(_ app: XCUIApplication, _ place: XCUIElement, labelContains text: String) {
        place.tap()
        let item = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .allElementsBoundByIndex.first { $0.isHittable && $0.identifier != "taskComposer.place" }
        guard let item else {
            attach(app, "FAIL-menu-\(text)")
            XCTFail("no \(text) in the Runs on menu\n\(app.debugDescription)")
            return
        }
        item.tap()
    }

    @MainActor
    private func type(_ app: XCUIApplication, _ text: String) {
        let field = any(app, "taskComposer.prompt")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the prompt field")
        field.tap()
        field.typeText(text)
    }

    @MainActor
    private func closeCloudChats(_ app: XCUIApplication) {
        // The machine page sits in the Cloud chats sheet; its root has Done.
        for _ in 0..<3 where !any(app, "workspaces.newTask").isHittable {
            let done = app.buttons["Done"].firstMatch
            if done.exists, done.isHittable { done.tap() } else if app.navigationBars.buttons.firstMatch.isHittable {
                app.navigationBars.buttons.firstMatch.tap()
            } else {
                app.swipeDown(velocity: .fast)
            }
            _ = any(app, "workspaces.newTask").waitForExistence(timeout: 2)
        }
        XCTAssertTrue(wait { self.any(app, "workspaces.newTask").isHittable }, "back on the Workspaces list\n\(app.debugDescription)")
    }

    @MainActor
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    private func wait(timeout: Double = 6, _ ok: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return ok()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
