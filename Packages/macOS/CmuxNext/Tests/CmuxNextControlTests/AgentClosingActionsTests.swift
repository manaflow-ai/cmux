import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// An agent's run that closes, ends, archives, disconnects or destroys something and names no target is refused
/// (`target_required`) before it is aimed anywhere: with no target such an action acts on what the person has
/// focused or selected, or, since a caller's run uses its own place, on the agent's own home (review of
/// 4b4017014c8: `cmux cloud archive-session` with no `--session` archived the agent's own session; a destructive
/// browser action reached the nearest browser, the person's; a screen or tab-group close reached the focused one).
///
/// This walks the app's real action catalog through `action.run`, so a new closing action cannot be added
/// without a decision: an action whose id or CLI name says it closes something and that takes a target must be
/// destructive in the catalog, in `ControlRouter.closingActions`, or listed in ``judgedSafe`` with its reason.
@MainActor @Suite(.timeLimit(.minutes(2))) struct AgentClosingActionsTests {
    /// What an id or CLI name says when the action closes, ends or removes something.
    static let closingWords = [
        "close", "remove", "archive", "discard", "disconnect", "kill", "quit", "clear", "delete", "stop", "reset", "forget",
        "detach", "eject", "stash", "terminat", "signout", "sign-out", "logout", "revoke", "destroy", "purge", "trash",
        "erase", "wipe", "unpair", "uninstall", "cancel", "abort", "restart", "reload", "hibernat", "suspend", "shutdown",
        "leave", "exit", "interrupt",
    ]

    /// Actions with such a name that take a target and are safe for an agent to run on its own place (or, for a
    /// browser action, on the browser nearest it) with no target named.
    static let judgedSafe: Set<String> = [
        // A look that is set back to its default (a name, an icon, a color, a theme, a zoom, a font size, a
        // background, table widths, a proxy or default-profile choice): nothing is closed or lost.
        "agentPaneZoomReset", "appearance.reset", "bookmark.clearIcon", "browserProfile.clearColor", "browserProfile.clearIcon",
        "browserProfile.clearProxy", "browserProfile.clearSpaceDefault", "browserProfile.clearWorkspaceDefault", "browserZoomReset",
        "canvasZoomReset", "fileEditorZoomReset", "machine.clearIcon", "markdownResetTableWidths", "markdownZoomReset",
        "palette.clearTabName", "palette.clearWorkspaceDescription", "palette.clearWorkspaceName", "palette.resetWorkspaceColor",
        "pane.clearBackground", "resetWorkspaceTerminalFontSize", "screen.clearColor", "screen.clearIcon", "screen.clearName",
        "screenGroup.clearIcon", "space.clearColor", "space.clearIcon", "space.clearTheme", "tab.clearIcon", "tabGroup.clearIcon",
        "terminal.clearTheme", "terminal.resetFontSize", "workspace.clearIcon", "workspace.clearTheme", "workspaceGroup.clearColor",
        "workspaceGroup.clearIcon",
        // A page, a view or a terminal screen that is loaded or drawn again: the tab and its program stay.
        "browser.extension.reload", "browserHardReload", "browserReload", "browserStop", "devtools.clearConsole", "devtools.close",
        "devtools.emptyCacheAndHardReload", "markdownReload", "reloadTab", "browser.resetPinnedTab", "clearScreenKeepScrollback",
        "resetTerminal", "resumeCommandClear", "terminal.clear",
        // Marks read, or takes one thing out of a group or a list the caller keeps; nothing closes.
        "clearWorkspaceNotifications", "workspaceGroup.clearNotifications", "removeWorkspaceFromGroup", "screenGroup.removeScreen",
        "tabGroup.removeTab", "checklistRemoveItem",
        // Opens something (a closed tab or workspace again, the checklist as a pane); the word is in its name only.
        "reopenClosedBrowserPanel", "reopenClosedWorkspace", "checklistOpenAsPane",
        // A setting, or a saved thing its required argument names (the target is not what goes away).
        "neverHibernateSite", "workspaceGroup.setAutoArchive", "tabGroup.deleteSaved",
    ]

    /// The agent's workspace (CallerOwnPlacementTests: an agent's terminal, the person's focus in another
    /// workspace) with the app's real catalog.
    static func snapshot() -> ControlSnapshot {
        var snapshot = CallerOwnPlacementTests.snapshot(right: [CallerOwnPlacementTests.pane("pane-web", [CallerOwnPlacementTests.browser("tab-web")])])
        snapshot.catalog = RegistryControlBridge.catalog(from: ActionRegistry.standard())
        return snapshot
    }

    static func says(_ action: ControlActionInfo) -> Bool {
        let name = (action.id + " " + action.cliName).lowercased()
        return closingWords.contains { name.contains($0) }
    }

    @Test func everyClosingActionOfTheRealCatalogHasADecision() {
        let catalog = Self.snapshot().catalog
        let undecided = catalog.actions.filter { action in
            !action.isDebugOnly && !action.targets.isEmpty && Self.says(action) && !ControlRouter.closesItsPlace(action)
                && !Self.judgedSafe.contains(action.id)
        }.map(\.id)
        #expect(undecided.isEmpty, """
            these actions say they close something and take a target: add each to ControlRouter.closingActions \
            (an agent must name its target) or to judgedSafe with the reason: \(undecided)
            """)
        // The lists name real actions only: a renamed action is not silently unguarded.
        let ids = Set(catalog.actions.map(\.id))
        #expect(ControlRouter.closingActions.subtracting(ids).isEmpty, "\(ControlRouter.closingActions.subtracting(ids).sorted())")
        #expect(Self.judgedSafe.subtracting(ids).isEmpty, "\(Self.judgedSafe.subtracting(ids).sorted())")
        #expect(ControlRouter.closingActions.isDisjoint(with: Self.judgedSafe))
    }

    @Test func anAgentsRunOfEachOneWithNoTargetIsRefusedAndNothingRuns() async throws {
        let executor = RecordingExecutor()
        let router = ControlRouter(identity: testIdentity(), executor: executor, configuration: .loadTolerant)
        let snapshot = Self.snapshot()
        router.snapshots.publish { $0 = snapshot }
        let closing = snapshot.catalog.actions.filter { ControlRouter.closesItsPlace($0) && $0.disabledFeature == nil }
        try #require(closing.count > 40, "the real catalog lists its closing actions: \(closing.count)")
        for action in closing {
            // `interactive`: a missing required argument is asked for later, so the run reaches its placement.
            let result = await router.handle(ControlRequest(id: "1", method: "action.run", params: [
                "action": .string(action.id), "interactive": true, "caller": CallerOwnPlacementTests.agent,
            ]))
            #expect(result.failure?.code == "target_required", "\(action.id) \(action.targets): \(String(describing: result))")
        }
        #expect(executor.last == nil, "ran \(String(describing: executor.last?.actionID))")
        // A person's shell is not refused: its close with no target closes its own tab, as it asked.
        let shell = CallerOwnPlacementTests.terminal("tab-agent", "term-agent", agent: nil)
        var plain = CallerOwnPlacementTests.snapshot(own: shell)
        plain.catalog = snapshot.catalog
        router.snapshots.publish { $0 = plain }
        _ = await router.handle(ControlRequest(id: "2", method: "action.run", params: ["action": "closeTab", "caller": CallerOwnPlacementTests.agent]))
        #expect(executor.last?.target == ControlTargetRef(kind: "tab", id: "tab-agent"))
    }
}
