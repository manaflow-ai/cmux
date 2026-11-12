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
            { dismissKeyboardTip(app); return nil },
        ])
    }

    /// The system keyboard's one-time "Speed up your typing" tip covers the sheet: put it away.
    @MainActor
    private static func dismissKeyboardTip(_ app: XCUIApplication) {
        let next = app.buttons["Continue"].firstMatch
        if next.waitForExistence(timeout: 1.5), next.isHittable { next.tap() }
    }

    /// Opens the sheet straight from launch (`-cmux-mobile-open-new-task`), the tip put away.
    @MainActor
    private static func openedAtLaunch(_ app: XCUIApplication) -> String? {
        guard any(app, "taskComposer.prompt").waitForExistence(timeout: 15) else { return "composer did not open" }
        dismissKeyboardTip(app)
        return nil
    }

    /// Drags the sheet a little at a time until `element` sits below the bar and above the bottom
    /// (its frame from the accessibility tree), so a capture shows it whole.
    @MainActor
    private static func scrollUntilBelowBar(_ app: XCUIApplication, _ element: XCUIElement) -> String? {
        guard element.waitForExistence(timeout: 10) else { return "no element to bring into view" }
        let screen = app.frame
        for _ in 0..<12 {
            let f = element.frame
            if f.minY > screen.height * 0.16, f.maxY < screen.height * 0.85 { return nil }
            let up = f.minY > screen.height * 0.85
            let from = CGVector(dx: 0.5, dy: up ? 0.6 : 0.3), to = CGVector(dx: 0.5, dy: up ? 0.45 : 0.42)
            app.coordinate(withNormalizedOffset: from).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: to))
            pause(0.5)
        }
        return "could not bring it below the bar"
    }

    /// A short drag up inside the sheet (a fraction of a screen), to bring the next rows in.
    @MainActor
    private static func nudgeUp(_ app: XCUIApplication, by fraction: Double = 0.3) {
        // From above the keyboard (its top is near 0.55): a drag there scrolls the form and puts the keyboard away.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: max(0.08, 0.45 - fraction))))
        pause(0.6)
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

    /// Back to the Workspaces list from a workspace's page (its tab page, then the workspace).
    @MainActor
    private static func backToList(_ app: XCUIApplication) -> String? {
        let new = any(app, "workspaces.new")
        for _ in 0..<4 {
            if new.waitForExistence(timeout: 2), onScreen(new) { return nil }
            // The workspace page's own chevron is "Workspaces" (its navigation bar is hidden); a
            // tab's page goes back to the workspace with "Back". The tab bar's button is not it.
            let tabBarFrame = app.tabBars.buttons["Workspaces"].exists ? app.tabBars.buttons["Workspaces"].frame : .null
            let chevron = app.buttons.matching(NSPredicate(format: "label == %@", "Workspaces")).allElementsBoundByIndex
                .first { $0.frame != tabBarFrame && $0.isHittable }
            let back = app.buttons["Back"].firstMatch
            if let chevron {
                chevron.tap()
            } else if back.exists, back.isHittable {
                back.tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
            }
        }
        if new.waitForExistence(timeout: 3) { return nil }
        // Say what was on screen, so a failed run's log shows the way back that was missed.
        let labels = app.buttons.allElementsBoundByIndex.filter(\.isHittable).prefix(30).map { "\($0.label)|\($0.identifier)" }
        return "could not get back to the Workspaces list; buttons: \(labels.joined(separator: ", "))"
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
                    // The keyboard covers the name field: drag the form to put it away first.
                    { app.swipeUp(); C.pause(0.6); return nil },
                    { C.tap(C.any(app, "taskComposer.name"), "name field") },
                    { C.any(app, "taskComposer.name").typeText("scroll perf"); return nil },
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
            // At Accessibility sizes the bar's hold is not reachable from XCUITest reliably (it lands
            // as a tap): the DEBUG launch argument opens the same sheet.
            Scene(group: g, id: "composer-large-type",
                  args: Self.list + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL", "-cmux-mobile-open-new-task"]) { app in
                C.steps([{ C.any(app, "taskComposer.prompt").waitForExistence(timeout: 15) ? nil : "composer did not open" },
                         { Self.type(app, "Fix the flaky upload test") }])
            },
            Scene(group: g, id: "composer-large-type-agents",
                  args: Self.list + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL", "-cmux-mobile-open-new-task"]) { app in
                C.steps([{ C.any(app, "taskComposer.prompt").waitForExistence(timeout: 15) ? nil : "composer did not open" },
                         { app.swipeUp(); C.pause(0.6); return nil }])
            },
            // The Mac still making it: the chat says Starting <agent>….
            Scene(group: g, id: "started-one-starting", args: Self.list + ["-cmux-mobile-mock-create-delay", "60"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }])
            },
            // A1: with no Mac starting agents from the phone, New Task is not offered.
            Scene(group: g, id: "entry-hidden-no-agents", args: Self.list + ["-cmux-mobile-no-agents"]) { app in
                C.longPress(C.any(app, "workspaces.new"), "New Workspace button")
            },
            // A1: a plain tap still makes a terminal workspace at once.
            Scene(group: g, id: "plain-tap-terminal", args: Self.list + ["-cmux-mobile-mock-create-delay", "60"]) { app in
                C.tap(C.any(app, "workspaces.new"), "New Workspace button")
            },
            // The rest of the hold menu, unchanged below New Task.
            Scene(group: g, id: "new-workspace-menu-rest", args: Self.list) { app in
                C.steps([{ C.longPress(C.any(app, "workspaces.new"), "New Workspace button") },
                         { app.swipeUp(); C.pause(0.8); return nil }])
            },
            // A3: four agents chosen; a fifth stays unchosen and the footer says why.
            Scene(group: g, id: "agents-at-limit", args: Self.list + ["-cmux-mobile-task-catalog", "many"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Review the release branch") },
                         { Self.nudgeUp(app, by: 0.35); return nil },
                         { C.tap(C.any(app, "taskComposer.agent.claude-cr"), "Router") },
                         { C.tap(C.any(app, "taskComposer.agent.claude-work"), "work") },
                         { C.tap(C.any(app, "taskComposer.agent.claude-review"), "review") },
                         { C.tap(C.any(app, "taskComposer.agent.claude-docs"), "docs, the fifth") },
                         { Self.nudgeUp(app, by: 0.2); return nil }])
            },
            // A3: a model the account can't use is listed with why and can't be chosen.
            Scene(group: g, id: "model-unavailable", args: Self.list + ["-cmux-mobile-task-catalog", "many"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Review the release branch") },
                         { Self.nudgeUp(app, by: 0.3); return nil },
                         { C.tap(C.any(app, "taskComposer.model.claude"), "Claude Code's model menu") }])
            },
            // A4: two Macs online: the Mac picker.
            Scene(group: g, id: "mac-picker", args: Self.list + ["-cmux-mobile-mock-second-mac"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Update the docs") },
                         { app.swipeUp(); C.pause(0.6); return nil },
                         { C.tap(C.any(app, "taskComposer.mac"), "Mac picker") }])
            },
            // A4: another Mac: the two agents chosen go (Start 2 becomes Start).
            Scene(group: g, id: "mac-switched-clears-agents", args: Self.list + ["-cmux-mobile-mock-second-mac"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Update the docs") },
                         { Self.nudgeUp(app, by: 0.1); return nil },
                         { C.tap(C.any(app, "taskComposer.agent.claude-cr"), "Router") },
                         { app.swipeUp(); C.pause(0.6); return nil },
                         { C.tap(C.any(app, "taskComposer.mac"), "Mac picker") },
                         { C.tap(app.buttons["MacBook Pro"].firstMatch, "MacBook Pro") },
                         { C.pause(1.5); return nil }])
            },
            // A8: Cancel keeps all of it: prompt, photos, agents (Start 2), then folder and name.
            Scene(group: g, id: "draft-full-kept-top", args: Self.list, env: ["CMUX_MOBILE_TASK_DRAFT_IMAGES": "2"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Match this design") },
                         { Self.nudgeUp(app, by: 0.1); return nil },
                         { C.tap(C.any(app, "taskComposer.agent.claude-cr"), "Router") },
                         { app.swipeUp(); C.pause(0.6); return nil },
                         { C.tap(C.any(app, "taskComposer.name"), "name field") },
                         { C.any(app, "taskComposer.name").typeText("design pass"); return nil },
                         { C.tap(C.any(app, "taskComposer.cancel"), "Cancel") },
                         { C.pause(1); return Self.openComposer(app) }])
            },
            Scene(group: g, id: "draft-full-kept-bottom", args: Self.list, env: ["CMUX_MOBILE_TASK_DRAFT_IMAGES": "2"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Match this design") },
                         { Self.nudgeUp(app, by: 0.1); return nil },
                         { C.tap(C.any(app, "taskComposer.agent.claude-cr"), "Router") },
                         { app.swipeUp(); C.pause(0.6); return nil },
                         { C.tap(C.any(app, "taskComposer.name"), "name field") },
                         { C.any(app, "taskComposer.name").typeText("design pass"); return nil },
                         { C.tap(C.any(app, "taskComposer.cancel"), "Cancel") },
                         { C.pause(1); return Self.openComposer(app) },
                         { app.swipeUp(); C.pause(0.6); return nil }])
            },
            // A10: the workspace is made but its task doesn't reach the agent, three ways.
            Scene(group: g, id: "delivery-not-sent", args: Self.list + ["-cmux-mobile-mock-create-delay", "1", "-cmux-mobile-task-delivery", "not-sent"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }, { C.pause(2.2); return nil }])
            },
            Scene(group: g, id: "delivery-uncertain", args: Self.list + ["-cmux-mobile-mock-create-delay", "1", "-cmux-mobile-task-delivery", "uncertain"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }, { C.pause(2.2); return nil }])
            },
            Scene(group: g, id: "delivery-refused", args: Self.list + ["-cmux-mobile-mock-create-delay", "1", "-cmux-mobile-task-delivery", "refused"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }, { C.pause(2.2); return nil }])
            },
            // A11 at Accessibility Large: the agent row with its model menu, and each list state.
            // The checked agent and its model menu, below the bar: scrolled until the menu is in view.
            Scene(group: g, id: "large-agent-row", args: Self.list + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL", "-cmux-mobile-open-new-task"]) { app in
                C.steps([{ Self.openedAtLaunch(app) }, { Self.type(app, "Fix it") },
                         { Self.nudgeUp(app, by: 0.1); return nil },
                         { Self.scrollUntilBelowBar(app, C.any(app, "taskComposer.model.claude")) }])
            },
            Scene(group: g, id: "large-agents-loading", args: Self.list + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL", "-cmux-mobile-open-new-task"] + ["-cmux-mobile-task-catalog", "slow"]) { app in
                C.steps([{ Self.openedAtLaunch(app) }, { Self.nudgeUp(app, by: 0.45); return nil }])
            },
            Scene(group: g, id: "large-agents-failed", args: Self.list + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL", "-cmux-mobile-open-new-task"] + ["-cmux-mobile-task-catalog", "failed"]) { app in
                C.steps([{ Self.openedAtLaunch(app) }, { Self.nudgeUp(app, by: 0.45); return nil }])
            },
            Scene(group: g, id: "large-agents-empty", args: Self.list + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL", "-cmux-mobile-open-new-task"] + ["-cmux-mobile-task-catalog", "empty"]) { app in
                C.steps([{ Self.openedAtLaunch(app) }, { Self.nudgeUp(app, by: 0.45); return nil }])
            },
            // Made: a new chat whose first message is the task, the agent answering.
            Scene(group: g, id: "started-one-opens", args: Self.list + ["-cmux-mobile-mock-create-delay", "1"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }, { C.pause(5); return nil }])
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
                         { Self.backToList(app) }, { Self.openComposer(app) }])
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
        let start = app.buttons["taskComposer.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertFalse(start.isEnabled, "Start is off with no prompt")
        XCTAssertNil(Self.type(app, "Fix the flaky upload test"))
        XCTAssertTrue(start.isEnabled, "Start is on with a prompt")
        start.tap()
        XCTAssertTrue(C.any(app, "taskComposer.prompt").waitForNonExistence(timeout: 5), "the sheet closes at once")
        XCTAssertTrue(C.label(app, contains: "Fix the flaky upload test").waitForExistence(timeout: 5),
                      "the opened workspace is titled for the task")
        XCTAssertNil(Self.backToList(app))
        XCTAssertNil(Self.openComposer(app))
        let left = C.any(app, "taskComposer.prompt").value as? String ?? ""
        XCTAssertTrue(left.isEmpty || left == "Describe the task…", "the prompt is cleared, got \(left)")
    }

    /// Start with two agents: two rows, one per agent, and the list stays on screen.
    @MainActor
    func testStartTwoMakesOneWorkspacePerAgent() {
        let app = launch(Self.list + ["-cmux-mobile-mock-create-delay", "30"])
        XCTAssertNil(Self.composeTwoAgents(app))
        let start = app.buttons["taskComposer.start"].firstMatch
        XCTAssertEqual(start.label, "Start 2")
        start.tap()
        XCTAssertTrue(C.label(app, contains: "Claude Code Router · Fix the flaky").waitForExistence(timeout: 5), "a row for Claude Code Router")
        XCTAssertTrue(C.label(app, contains: "Claude Code · Fix the flaky").exists, "a row for Claude Code")
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
