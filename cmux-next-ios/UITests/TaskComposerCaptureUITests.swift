import XCTest

/// New Task (the task composer): every state, light and dark, on mock data with real taps.
/// Captures are named `uistate~~8 New Task~~<id>~~<look>` (see `UIStateCapture.swift`); the
/// behavior checks (`testStart…`) fail the run when the composer does not do its job.
final class TaskComposerCaptureUITests: UIStateCaptureCase {
    typealias C = UIStateCaptureCase
    private static let list = ["-cmux-mobile-tab", "workspaces"]
    private static let group = "8 New Task"

    @MainActor
    private static func openComposer(_ app: XCUIApplication) -> String? {
        steps([
            { longPress(any(app, "workspaces.new"), "New Workspace button") },
            { tap(any(app, "workspaces.newTask"), "New Task…") },
            { any(app, "taskComposer.prompt").waitForExistence(timeout: 10) ? nil : "composer did not open" },
        ])
    }

    @MainActor
    private static func type(_ app: XCUIApplication, _ text: String) -> String? {
        let field = any(app, "taskComposer.prompt")
        guard field.waitForExistence(timeout: 10) else { return "no prompt field" }
        field.tap()
        field.typeText(text)
        return nil
    }

    @MainActor
    private static func composeTwoAgents(_ app: XCUIApplication) -> String? {
        steps([
            { openComposer(app) },
            { type(app, "Fix the flaky upload test and open a PR") },
            { tap(any(app, "taskComposer.agent.claude-cr"), "Claude Code Router row") },
        ])
    }

    @MainActor
    func testNewTaskStates() {
        let g = Self.group
        capture([
            Scene(group: g, id: "new-workspace-menu", args: Self.list) { app in
                C.longPress(C.any(app, "workspaces.new"), "New Workspace button")
            },
            Scene(group: g, id: "composer-empty", args: Self.list) { app in Self.openComposer(app) },
            Scene(group: g, id: "composer-typed", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test and open a PR") }])
            },
            Scene(group: g, id: "composer-two-agents", args: Self.list) { app in
                C.steps([{ Self.composeTwoAgents(app) }, { app.swipeUp(); return nil }])
            },
            Scene(group: g, id: "composer-model-menu", args: Self.list) { app in
                C.steps([{ Self.composeTwoAgents(app) }, { C.tap(C.any(app, "taskComposer.model.claude-cr"), "model menu") }])
            },
            Scene(group: g, id: "composer-folder-menu", args: Self.list) { app in
                C.steps([
                    { Self.openComposer(app) },
                    { Self.type(app, "Update the docs") },
                    { app.swipeUp(); return nil },
                    { C.tap(C.any(app, "taskComposer.folder"), "folder picker") },
                ])
            },
            Scene(group: g, id: "composer-named-scrolled", args: Self.list) { app in
                C.steps([
                    { Self.openComposer(app) },
                    { Self.type(app, "Profile the list scroll\nand fix any hitch over 8 ms") },
                    { C.tap(C.any(app, "taskComposer.name"), "name field") },
                    { app.typeText("scroll perf"); return nil },
                ])
            },
            Scene(group: g, id: "composer-photos", args: Self.list, env: ["CMUX_MOBILE_TASK_DRAFT_IMAGES": "3"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Match this design") }])
            },
            Scene(group: g, id: "composer-photo-limit", args: Self.list, env: ["CMUX_MOBILE_TASK_DRAFT_IMAGES": "6"]) { app in
                C.steps([{ Self.openComposer(app) }, { app.swipeUp(); return nil }])
            },
            Scene(group: g, id: "composer-system-photo-picker", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { app.swipeUp(); return nil },
                         { C.tap(C.any(app, "taskComposer.addPhotos"), "Add Photos") }, { C.pause(2); return nil }])
            },
            Scene(group: g, id: "agents-loading", args: Self.list + ["-cmux-mobile-task-catalog", "slow"]) { app in
                Self.openComposer(app)
            },
            Scene(group: g, id: "agents-failed", args: Self.list + ["-cmux-mobile-task-catalog", "failed"]) { app in
                C.steps([{ Self.openComposer(app) }, { app.swipeUp(); return nil }])
            },
            Scene(group: g, id: "agents-empty", args: Self.list + ["-cmux-mobile-task-catalog", "empty"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Anything") }, { app.swipeUp(); return nil }])
            },
            Scene(group: g, id: "composer-large-type", args: Self.list + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") }])
            },
            Scene(group: g, id: "started-one-opens", args: Self.list + ["-cmux-mobile-mock-create-delay", "60"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }])
            },
            Scene(group: g, id: "started-two-rows", args: Self.list + ["-cmux-mobile-mock-create-delay", "60"]) { app in
                C.steps([{ Self.composeTwoAgents(app) }, { C.tap(C.any(app, "taskComposer.start"), "Start 2") }])
            },
            Scene(group: g, id: "refused-toast", args: Self.list + ["-cmux-mobile-refuse-next-create"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }, { C.pause(1.2); return nil }])
            },
            Scene(group: g, id: "refused-draft-restored", args: Self.list + ["-cmux-mobile-refuse-next-create"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }, { C.pause(3); return nil },
                         { app.navigationBars.buttons.firstMatch.tap(); C.pause(1); return Self.openComposer(app) }])
            },
            Scene(group: g, id: "draft-kept-after-cancel", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Half-written idea") },
                         { C.tap(C.any(app, "taskComposer.cancel"), "Cancel") }, { C.pause(1); return Self.openComposer(app) }])
            },
        ])
    }

    /// Start with one agent: the sheet closes, the new workspace opens at once on its agent
    /// tab named for the task, and the composer's prompt is cleared for the next task.
    @MainActor
    func testStartOneOpensTheWorkspaceAndClearsThePrompt() {
        let app = launch(Self.list + ["-cmux-mobile-mock-create-delay", "4"])
        XCTAssertNil(Self.openComposer(app))
        XCTAssertFalse(C.any(app, "taskComposer.start").isEnabled, "Start is off with no prompt")
        XCTAssertNil(Self.type(app, "Fix the flaky upload test"))
        XCTAssertTrue(C.any(app, "taskComposer.start").isEnabled)
        C.any(app, "taskComposer.start").tap()
        XCTAssertTrue(C.any(app, "taskComposer.prompt").waitForNonExistence(timeout: 5), "the sheet closes at once")
        XCTAssertTrue(app.staticTexts["Fix the flaky upload test"].firstMatch.waitForExistence(timeout: 5),
                      "the opened workspace is titled for the task")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertNil(Self.openComposer(app))
        let left = C.any(app, "taskComposer.prompt").value as? String ?? ""
        XCTAssertTrue(left.isEmpty || left == "Describe the task…", "the prompt is cleared, got \(left)")
    }

    /// Start with two agents: two rows, one per agent, and the list stays on screen.
    @MainActor
    func testStartTwoMakesOneWorkspacePerAgent() {
        let app = launch(Self.list + ["-cmux-mobile-mock-create-delay", "30"])
        XCTAssertNil(Self.composeTwoAgents(app))
        let start = C.any(app, "taskComposer.start")
        XCTAssertEqual(start.label, "Start 2")
        start.tap()
        XCTAssertTrue(app.staticTexts["Fix the flaky upload test and open a PR · Claude Code"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fix the flaky upload test and open a PR · Claude Code Router"].firstMatch.exists)
        XCTAssertTrue(C.any(app, "workspaces.new").exists, "the list stays on screen")
    }

    @MainActor
    private func launch(_ args: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_MOBILE_MOCK_AUTH"] = "1"
        app.launchArguments += ["-cmuxMobile.setupComplete", "YES"] + args
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 20)
        C.pause(2)
        pickTeamIfAsked(app)
        return app
    }
}
