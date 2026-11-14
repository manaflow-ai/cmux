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

    /// A step that checks where the scene got to: nil when `ok`, else why (so a capture that
    /// missed its state is reported as missed, not attached as if it showed it).
    @MainActor
    private static func check(_ ok: @autoclosure () -> Bool, _ why: String, timeout: Double = 4) -> String? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if ok() { return nil }; pause(0.3) }
        return ok() ? nil : why
    }

    @MainActor
    private static func type(_ app: XCUIApplication, _ text: String) -> String? {
        let field = any(app, "taskComposer.prompt")
        guard field.waitForExistence(timeout: 10) else { return "no prompt field" }
        field.tap()
        field.typeText(text)
        return nil
    }

    /// Opens the Agents list from its pill.
    @MainActor
    private static func openAgents(_ app: XCUIApplication) -> String? {
        steps([
            { tap(any(app, "taskComposer.agents"), "Agents pill") },
            { any(app, "taskComposer.agents.done").waitForExistence(timeout: 6) ? nil : "the Agents list did not open" },
        ])
    }

    @MainActor
    private static func closeSheet(_ app: XCUIApplication, _ id: String) -> String? {
        steps([{ tap(any(app, id), id) }, { pause(0.8); return nil }])
    }

    @MainActor
    private static func openOptions(_ app: XCUIApplication) -> String? {
        steps([
            { tap(any(app, "taskComposer.options"), "Task Options") },
            { any(app, "taskComposer.options.done").waitForExistence(timeout: 6) ? nil : "Task Options did not open" },
        ])
    }

    @MainActor
    private static func composeTwoAgents(_ app: XCUIApplication) -> String? {
        steps([
            { openComposer(app) },
            { type(app, "Fix the flaky upload test and open a PR") },
            { openAgents(app) },
            { tap(any(app, "taskComposer.agent.claude-cr"), "Claude Code Router row") },
            { closeSheet(app, "taskComposer.agents.done") },
            { check(app.buttons["taskComposer.start"].firstMatch.label == "Start 2", "two agents not picked") },
        ])
    }

    /// Back, then Save Draft in the dialog that asks.
    @MainActor
    private static func leaveSavingDraft(_ app: XCUIApplication) -> String? {
        steps([
            { tap(any(app, "taskComposer.cancel"), "Back") },
            { tap(app.buttons["Save Draft"].firstMatch, "Save Draft") },
            { any(app, "taskComposer.prompt").waitForNonExistence(timeout: 5) ? nil : "New Task did not close" },
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
        let large = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL", "-cmux-mobile-open-new-task"]
        capture([
            // Entry (A1).
            Scene(group: g, id: "new-workspace-menu", args: Self.list) { app in
                C.longPress(C.any(app, "workspaces.new"), "New Workspace button")
            },
            Scene(group: g, id: "new-workspace-menu-rest", args: Self.list) { app in
                C.steps([{ C.longPress(C.any(app, "workspaces.new"), "New Workspace button") },
                         { app.swipeUp(); C.pause(0.8); return nil }])
            },
            Scene(group: g, id: "entry-hidden-no-agents", args: Self.list + ["-cmux-mobile-no-agents"]) { app in
                C.steps([{ C.longPress(C.any(app, "workspaces.new"), "New Workspace button") },
                         { Self.check(!C.any(app, "workspaces.newTask").exists, "New Task is offered") }])
            },
            Scene(group: g, id: "plain-tap-terminal", args: Self.list + ["-cmux-mobile-mock-create-delay", "60"]) { app in
                C.tap(C.any(app, "workspaces.new"), "New Workspace button")
            },
            // The canvas and the row above the keyboard (A2).
            Scene(group: g, id: "composer-empty", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) },
                         { Self.check(!app.buttons["taskComposer.start"].firstMatch.isEnabled, "Start is on with no prompt") }])
            },
            Scene(group: g, id: "composer-typed", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test and open a PR") },
                         { Self.check(app.buttons["taskComposer.start"].firstMatch.isEnabled, "Start is off with a prompt") }])
            },
            Scene(group: g, id: "composer-multiline", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) },
                         { Self.type(app, "Profile the list scroll\nand fix any hitch over 8 ms.\nAttach a trace to the PR.") }])
            },
            Scene(group: g, id: "composer-keyboard-down", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Update the docs") },
                         { app.swipeDown(); C.pause(0.8); return nil }])
            },
            // Agents and models (A3).
            Scene(group: g, id: "agents-list", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") }, { Self.openAgents(app) }])
            },
            Scene(group: g, id: "composer-two-agents", args: Self.list) { app in
                Self.composeTwoAgents(app)
            },
            Scene(group: g, id: "agents-list-two", args: Self.list) { app in
                C.steps([{ Self.composeTwoAgents(app) }, { Self.openAgents(app) }])
            },
            Scene(group: g, id: "composer-model-menu", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.modelPill"), "model pill") }])
            },
            Scene(group: g, id: "agent-row-model-menu", args: Self.list) { app in
                C.steps([{ Self.composeTwoAgents(app) }, { Self.openAgents(app) },
                         { C.tap(C.any(app, "taskComposer.model.claude-cr"), "Router's model menu") }])
            },
            Scene(group: g, id: "agents-at-limit", args: Self.list + ["-cmux-mobile-task-catalog", "many"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Review the release branch") }, { Self.openAgents(app) },
                         { C.tap(C.any(app, "taskComposer.agent.claude-cr"), "Router") },
                         { C.tap(C.any(app, "taskComposer.agent.claude-work"), "work") },
                         { C.tap(C.any(app, "taskComposer.agent.claude-review"), "review") },
                         { C.tap(C.any(app, "taskComposer.agent.claude-docs"), "docs, the fifth") },
                         { Self.check(!C.any(app, "taskComposer.agent.claude-docs").isSelected, "a fifth agent was picked") }])
            },
            Scene(group: g, id: "composer-four-agents", args: Self.list + ["-cmux-mobile-task-catalog", "many"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Review the release branch") }, { Self.openAgents(app) },
                         { C.tap(C.any(app, "taskComposer.agent.claude-cr"), "Router") },
                         { C.tap(C.any(app, "taskComposer.agent.claude-work"), "work") },
                         { C.tap(C.any(app, "taskComposer.agent.claude-review"), "review") },
                         { Self.closeSheet(app, "taskComposer.agents.done") },
                         { Self.check(app.buttons["taskComposer.start"].firstMatch.label == "Start 4", "not four agents") }])
            },
            Scene(group: g, id: "model-unavailable", args: Self.list + ["-cmux-mobile-task-catalog", "many"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Review the release branch") },
                         { C.tap(C.any(app, "taskComposer.modelPill"), "model pill") }])
            },
            Scene(group: g, id: "model-unavailable-tapped", args: Self.list + ["-cmux-mobile-task-catalog", "many"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Review the release branch") },
                         { C.tap(C.any(app, "taskComposer.modelPill"), "model pill") },
                         { C.tap(C.label(app, contains: "Opus Max"), "Opus Max") },
                         { C.pause(1); return nil },
                         { Self.check(!C.any(app, "taskComposer.modelPill").label.contains("Opus Max"), "Opus Max was chosen") }])
            },
            Scene(group: g, id: "agents-loading", args: Self.list + ["-cmux-mobile-task-catalog", "slow"]) { app in
                C.steps([{ Self.openComposer(app) },
                         { Self.check((C.any(app, "taskComposer.agents").value as? String) == "Loading", "agents not loading") }])
            },
            Scene(group: g, id: "agents-failed", args: Self.list + ["-cmux-mobile-task-catalog", "failed"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Anything") }])
            },
            Scene(group: g, id: "agents-failed-list", args: Self.list + ["-cmux-mobile-task-catalog", "failed"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.openAgents(app) },
                         { Self.check(C.any(app, "taskComposer.agents.retry").exists, "no Try Again") }])
            },
            Scene(group: g, id: "agents-empty", args: Self.list + ["-cmux-mobile-task-catalog", "empty"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Anything") },
                         { Self.check(!app.buttons["taskComposer.start"].firstMatch.isEnabled, "Start is on with no agent") }])
            },
            Scene(group: g, id: "agents-empty-list", args: Self.list + ["-cmux-mobile-task-catalog", "empty"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.openAgents(app) }])
            },
            // Task Options: name, Mac, folder (A4).
            Scene(group: g, id: "options", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Update the docs") }, { Self.openOptions(app) }])
            },
            Scene(group: g, id: "options-named", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Update the docs") }, { Self.openOptions(app) },
                         { C.tap(C.any(app, "taskComposer.name"), "name field") },
                         { C.any(app, "taskComposer.name").typeText("docs pass"); return nil }])
            },
            Scene(group: g, id: "options-folder-menu", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Update the docs") }, { Self.openOptions(app) },
                         { C.tap(C.any(app, "taskComposer.folder"), "folder picker") }])
            },
            Scene(group: g, id: "options-two-agents", args: Self.list) { app in
                C.steps([{ Self.composeTwoAgents(app) }, { Self.openOptions(app) },
                         { Self.check(C.any(app, "taskComposer.titles").exists, "no workspace titles") }])
            },
            Scene(group: g, id: "options-mac-picker", args: Self.list + ["-cmux-mobile-mock-second-mac"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Update the docs") }, { Self.openOptions(app) },
                         { C.tap(C.any(app, "taskComposer.mac"), "Mac picker") }])
            },
            Scene(group: g, id: "mac-switched-clears-agents", args: Self.list + ["-cmux-mobile-mock-second-mac"]) { app in
                C.steps([{ Self.composeTwoAgents(app) }, { Self.openOptions(app) },
                         { C.tap(C.any(app, "taskComposer.mac"), "Mac picker") },
                         { C.tap(app.buttons["MacBook Pro"].firstMatch, "MacBook Pro") }, { C.pause(1); return nil },
                         { Self.closeSheet(app, "taskComposer.options.done") },
                         { Self.check(app.buttons["taskComposer.start"].firstMatch.label == "Start", "the agents stayed") }])
            },
            // Photos (A5).
            Scene(group: g, id: "attach-menu", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Match this design") },
                         { C.tap(C.any(app, "taskComposer.attach"), "attach") }])
            },
            Scene(group: g, id: "composer-photos", args: Self.list, env: ["CMUX_MOBILE_TASK_DRAFT_IMAGES": "3"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Match this design") }])
            },
            Scene(group: g, id: "composer-photo-limit", args: Self.list, env: ["CMUX_MOBILE_TASK_DRAFT_IMAGES": "6"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Match this design") },
                         { Self.check(C.any(app, "taskComposer.photosFull").exists, "no limit note") }])
            },
            Scene(group: g, id: "composer-system-photo-picker", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { C.tap(C.any(app, "taskComposer.attach"), "attach") },
                         { C.tap(C.any(app, "taskComposer.addPhotos"), "Photos") }, { C.pause(2); return nil }])
            },
            // After Start (A6, A7).
            Scene(group: g, id: "started-one-starting", args: Self.list + ["-cmux-mobile-mock-create-delay", "60"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }])
            },
            Scene(group: g, id: "started-one-opens", args: Self.list + ["-cmux-mobile-mock-create-delay", "1"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }, { C.pause(5); return nil }])
            },
            Scene(group: g, id: "started-two-rows", args: Self.list + ["-cmux-mobile-mock-create-delay", "60"]) { app in
                C.steps([{ Self.composeTwoAgents(app) }, { C.tap(C.any(app, "taskComposer.start"), "Start 2") }])
            },
            // Drafts (A8).
            Scene(group: g, id: "leave-asks-to-save", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Half-written idea") },
                         { C.tap(C.any(app, "taskComposer.cancel"), "Back") },
                         { Self.check(app.buttons["Save Draft"].exists, "no Save Draft") }])
            },
            Scene(group: g, id: "drafts-empty", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { C.tap(C.any(app, "taskComposer.drafts"), "Drafts") },
                         { Self.check(C.any(app, "taskComposer.drafts.empty").exists, "no empty Drafts") }])
            },
            Scene(group: g, id: "drafts-list", args: Self.list, env: ["CMUX_MOBILE_TASK_DRAFT_IMAGES": "2"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Match this design") }, { Self.leaveSavingDraft(app) },
                         { Self.openComposer(app) }, { Self.type(app, "Update the docs") }, { Self.leaveSavingDraft(app) },
                         { Self.openComposer(app) }, { C.tap(C.any(app, "taskComposer.drafts"), "Drafts") },
                         { Self.check(app.buttons.matching(identifier: "taskComposer.draftRow").count == 2, "not two drafts") }])
            },
            Scene(group: g, id: "draft-resumed", args: Self.list, env: ["CMUX_MOBILE_TASK_DRAFT_IMAGES": "2"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Match this design") },
                         { Self.openAgents(app) }, { C.tap(C.any(app, "taskComposer.agent.claude-cr"), "Router") },
                         { Self.closeSheet(app, "taskComposer.agents.done") },
                         { Self.leaveSavingDraft(app) },
                         { Self.openComposer(app) },
                         { Self.check(((C.any(app, "taskComposer.prompt").value as? String) ?? "").isEmpty, "the next task did not start empty") },
                         { C.tap(C.any(app, "taskComposer.drafts"), "Drafts") },
                         { C.tap(app.buttons["taskComposer.draftRow"].firstMatch, "the draft") }, { C.pause(1); return nil },
                         { Self.check((C.any(app, "taskComposer.prompt").value as? String) == "Match this design", "the prompt did not come back") },
                         { Self.check(app.buttons["taskComposer.start"].firstMatch.label == "Start 2", "the agents did not come back") },
                         { Self.check(C.any(app, "taskComposer.photo").exists, "the photos did not come back") }])
            },
            Scene(group: g, id: "draft-folder-kept", args: Self.list) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Update the docs") }, { Self.openOptions(app) },
                         { C.tap(C.any(app, "taskComposer.folder"), "folder picker") },
                         { C.tap(app.buttons["web"].firstMatch, "web") }, { C.pause(0.8); return nil },
                         { Self.closeSheet(app, "taskComposer.options.done") },
                         { Self.leaveSavingDraft(app) },
                         { Self.openComposer(app) },
                         { C.tap(C.any(app, "taskComposer.drafts"), "Drafts") },
                         { C.tap(app.buttons["taskComposer.draftRow"].firstMatch, "the draft") }, { C.pause(1); return nil },
                         { Self.openOptions(app) },
                         { Self.check(C.label(app, contains: "Development/web").exists, "the folder did not stay web") }])
            },
            // A refusal (A9) and a task that doesn't reach its agent (A10).
            Scene(group: g, id: "refused-toast", args: Self.list + ["-cmux-mobile-refuse-next-create"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }, { C.pause(1.2); return nil }])
            },
            Scene(group: g, id: "refused-draft-restored", args: Self.list + ["-cmux-mobile-refuse-next-create"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }, { C.pause(3); return nil },
                         { Self.backToList(app) }, { Self.openComposer(app) },
                         { Self.check(C.any(app, "taskComposer.refusal").exists, "no refusal banner") }])
            },
            Scene(group: g, id: "delivery-not-sent", args: Self.list + ["-cmux-mobile-mock-create-delay", "1", "-cmux-mobile-task-delivery", "not-sent"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }, { C.pause(2.2); return nil },
                         { Self.check(C.label(app, contains: "ready to send").exists, "no not-sent toast") }])
            },
            Scene(group: g, id: "delivery-uncertain", args: Self.list + ["-cmux-mobile-mock-create-delay", "1", "-cmux-mobile-task-delivery", "uncertain"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }, { C.pause(2.2); return nil }])
            },
            Scene(group: g, id: "delivery-refused", args: Self.list + ["-cmux-mobile-mock-create-delay", "1", "-cmux-mobile-task-delivery", "refused"]) { app in
                C.steps([{ Self.openComposer(app) }, { Self.type(app, "Fix the flaky upload test") },
                         { C.tap(C.any(app, "taskComposer.start"), "Start") }, { C.pause(2.2); return nil }])
            },
            // Accessibility Large (A11).
            Scene(group: g, id: "large-composer", args: Self.list + large) { app in
                C.steps([{ Self.openedAtLaunch(app) }, { Self.type(app, "Fix the flaky upload test") }])
            },
            Scene(group: g, id: "large-agents-list", args: Self.list + large) { app in
                C.steps([{ Self.openedAtLaunch(app) }, { Self.openAgents(app) }])
            },
            Scene(group: g, id: "large-options", args: Self.list + large) { app in
                C.steps([{ Self.openedAtLaunch(app) }, { Self.openOptions(app) }])
            },
            Scene(group: g, id: "large-agents-loading", args: Self.list + large + ["-cmux-mobile-task-catalog", "slow"]) { app in
                Self.openedAtLaunch(app)
            },
            Scene(group: g, id: "large-agents-failed", args: Self.list + large + ["-cmux-mobile-task-catalog", "failed"]) { app in
                C.steps([{ Self.openedAtLaunch(app) }, { Self.openAgents(app) }])
            },
            Scene(group: g, id: "large-agents-empty", args: Self.list + large + ["-cmux-mobile-task-catalog", "empty"]) { app in
                C.steps([{ Self.openedAtLaunch(app) }, { Self.openAgents(app) }])
            },
            Scene(group: g, id: "large-drafts", args: Self.list + large) { app in
                C.steps([{ Self.openedAtLaunch(app) }, { Self.type(app, "Update the docs") }, { Self.leaveSavingDraft(app) },
                         { Self.openComposer(app) }, { C.tap(C.any(app, "taskComposer.drafts"), "Drafts") }])
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
        XCTAssertTrue(left.isEmpty, "the prompt is cleared, got \(left)")
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

    /// Drafts: leaving with a task asks, Save Draft keeps it, the next task starts empty, and the
    /// drafts list opens it again as it was.
    @MainActor
    func testSaveADraftAndResumeIt() {
        let app = launch(Self.list)
        XCTAssertNil(Self.openComposer(app))
        XCTAssertNil(Self.type(app, "Saved for later"))
        XCTAssertNil(Self.leaveSavingDraft(app))
        XCTAssertNil(Self.openComposer(app))
        XCTAssertEqual(C.any(app, "taskComposer.prompt").value as? String ?? "", "", "the next task starts empty")
        XCTAssertNil(C.tap(C.any(app, "taskComposer.drafts"), "Drafts"))
        let row = app.buttons["taskComposer.draftRow"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the saved draft is listed")
        XCTAssertTrue(row.label.contains("Saved for later"))
        row.tap()
        XCTAssertTrue(C.any(app, "taskComposer.prompt").waitForExistence(timeout: 5))
        XCTAssertEqual(C.any(app, "taskComposer.prompt").value as? String, "Saved for later")
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
