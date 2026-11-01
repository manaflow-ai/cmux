import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextPalette
@testable import CmuxNextTabs
import Foundation
import Testing

/// The tab menu and the palette act on the same tabs (Lawrence 2026-10-19: "right-click to make
/// tab groups is broken but the Cmd-Shift-P path works ... eliminate this entire error class").
/// Both run one registered action by one id: the menu with the right-clicked tab as the target,
/// the palette with no target (the focused tab). A tab group action acts on that tab and, when it
/// is one of several selected tabs, on every selected tab (`AppActionContext.actionTabs`); the CLI
/// and MCP name the tabs with `tabs`. Runs against a same-tree cmux-tui daemon, as the app does.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TabSelectionActionsTests {
    /// The window's one pane with `count` tabs, its strip synced.
    private static func pane(with count: Int, _ services: AppServices, _ connection: DaemonConnection) async throws -> PaneController {
        let pane = try #require(services.windows.active?.workspaceContent?.panes.values.first)
        for _ in pane.pane.tabs.count..<max(count, pane.pane.tabs.count) { _ = try await connection.newTab(in: pane.pane.handle) }
        try await PinnedPageTests.until({ pane.stripModel.tabs.count >= count }, report: { "\(pane.stripModel.tabs.map(\.id))" })
        return pane
    }

    /// Clicks tab `range.lowerBound` and Shift-clicks `range.upperBound` (display indexes), as the strip does.
    private static func select(_ range: ClosedRange<Int>, in pane: PaneController) async throws -> [StripTabID] {
        let ids = pane.stripModel.orderedTabs.map(\.id)
        for (id, click) in [(ids[range.lowerBound], TabMultiSelection.Click.plain), (ids[range.upperBound], .range)] {
            if let next = pane.stripModel.click(id, click) { pane.select(next) }
            try await PinnedPageTests.until({ pane.stripModel.selectedID == id })
        }
        let selected = Array(ids[range])
        try await PinnedPageTests.until({ pane.stripModel.selectedTabIDs == selected }, report: { "selected \(pane.stripModel.selectedTabIDs)" })
        return selected
    }

    private static func rows(_ menu: NSMenu) -> [NSMenuItem] {
        func all(_ items: [NSMenuItem]) -> [NSMenuItem] { items.flatMap { [$0] + ($0.submenu.map { all($0.items) } ?? []) } }
        return all(menu.items)
    }

    /// Runs a context menu row: what `ActionMenuTarget.performAction` runs. Returns its refusal.
    private static func click(_ item: NSMenuItem, _ services: AppServices) -> String? {
        guard let run = ActionRegistry.menuRun(of: item) else { return "not an action row" }
        return services.registry.capturingRefusal {
            _ = services.registry.perform(run.id, invocation: ActionInvocation(target: run.target, arguments: run.arguments))
        }
    }

    /// Whether `ids` are in one tab group.
    private static func grouped(_ ids: [StripTabID], in pane: PaneController) -> Bool {
        let groups = Set(ids.map { pane.tab($0)?.tabGroup?.rawValue })
        return groups.count == 1 && !groups.contains(nil)
    }

    @Test func theTabMenuGroupsEverySelectedTab() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 4, services, connection)
            let ids = try await Self.select(1...3, in: pane)
            let menu = try #require(pane.contextMenu(for: .tab(ids[0], selection: pane.stripModel.contextSelection(for: ids[0]))))
            let row = try #require(Self.rows(menu).first { ActionRegistry.menuRun(of: $0)?.id == "tabGroup.create" }, "no New Tab Group row")
            #expect(row.title == NSMenu.tabSelectionTitle("tabGroup.create", pins: true), "the row does not say it groups the selected tabs")
            let refusal = Self.click(row, services)
            #expect(refusal == nil, "the tab menu's New Tab Group refused: \(refusal ?? "")")
            try await PinnedPageTests.until({ Self.grouped(ids, in: pane) }, report: { "groups \(ids.map { pane.tab($0)?.tabGroup?.rawValue })" })
            #expect(pane.tab(pane.stripModel.orderedTabs[0].id)?.tabGroup == nil, "an unselected tab joined the group")
        }
    }

    @Test func thePaletteGroupsTheSameSelectedTabs() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 4, services, connection)
            let ids = try await Self.select(0...2, in: pane)
            #expect(services.registry.action(for: "tabGroup.create")?.paletteTitle?() == NSMenu.tabSelectionTitle("tabGroup.create", pins: true))
            // The palette runs the action with no target: the focused pane's active tab.
            let refusal = services.registry.capturingRefusal { _ = services.registry.perform("tabGroup.create", invocation: ActionInvocation()) }
            #expect(refusal == nil, "the palette's New Tab Group refused: \(refusal ?? "")")
            try await PinnedPageTests.until({ Self.grouped(ids, in: pane) }, report: { "groups \(ids.map { pane.tab($0)?.tabGroup?.rawValue })" })
        }
    }

    @Test func theCLINamesTheTabsItGroups() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 3, services, connection)
            let ids = Array(pane.stripModel.orderedTabs.map(\.id)[1...2])
            let invocation = ActionInvocation(arguments: ["tabs": .string(ids.map(\.rawValue).joined(separator: ","))])
            let refusal = services.registry.capturingRefusal { _ = services.registry.perform("tabGroup.create", invocation: invocation) }
            #expect(refusal == nil, "tabGroup.create with tabs refused: \(refusal ?? "")")
            try await PinnedPageTests.until({ Self.grouped(ids, in: pane) }, report: { "groups \(ids.map { pane.tab($0)?.tabGroup?.rawValue })" })
            #expect(pane.tab(pane.stripModel.orderedTabs[0].id)?.tabGroup == nil)
        }
    }

    /// #24913: a right-click on a tab that is not selected selected it while the menu was built, and
    /// the focus move made a Chromium page window key inside the right-click (a 10 s stall on macOS
    /// 14 and 15). Building the menu selects nothing and moves no focus; its rows act on that tab.
    @Test func theTabMenuOfAnotherTabSelectsNothing() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 3, services, connection)
            let selected = try #require(pane.stripModel.selectedID)
            let other = try #require(pane.stripModel.orderedTabs.map(\.id).first { $0 != selected })
            let focus = try #require(pane.workspace?.focus)
            let before = focus.currentState()
            let menu = try #require(pane.contextMenu(for: .tab(other, selection: pane.stripModel.contextSelection(for: other))))
            await Task.yield()
            #expect(pane.stripModel.selectedID == selected, "building the menu selected \(String(describing: pane.stripModel.selectedID))")
            #expect(focus.currentState().resolved == before.resolved, "building the menu moved focus to \(focus.currentState().resolved)")
            let runs = Self.rows(menu).compactMap(ActionRegistry.menuRun(of:))
            #expect(!runs.isEmpty)
            #expect(runs.allSatisfy { $0.target == ActionTargetRef(kind: .tab, id: other.rawValue) }, "a row does not act on the right-clicked tab")
        }
    }

    /// The real Cmd-Shift-P palette (`RegistryPaletteProvider`), on a terminal tab: Save and Close
    /// takes browser pages only, so its three tab rows are disabled there with the run's reason, as
    /// the tab menu disables them, instead of enabled and refused after the click.
    @Test func thePaletteDisablesSaveAndCloseOnATerminalTab() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 1, services, connection)
            let id = try #require(pane.stripModel.selectedID)
            try #require(pane.tab(id)?.kind == .pty, "the focused tab is not a terminal")
            let items = RegistryPaletteProvider(registry: services.registry).makeItems()
            for action in ["tab.stash", "tab.stashToRight", "tab.stashOthers"] {
                let row = try #require(items.first { $0.id == "action:\(action)" }, "no palette row for \(action)")
                #expect(!row.isEnabled, "the palette offers \(action) on a terminal tab, and its run refuses after the click")
                #expect(row.subtitle == StashHandlerStrings.noPage, "\(action) says \(row.subtitle ?? "nothing")")
            }
        }
    }

    /// The bug class: every row of the tab menu is a bound registered action that targets the
    /// right-clicked tab, and it can run exactly when the palette's run of the same action on the
    /// same (focused) tab can. A row enabled for one and refused or hidden for the other is a
    /// menu-only or palette-only path.
    @Test func everyTabMenuRowRunsLikeThePaletteOnTheSameTab() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let pane = try await Self.pane(with: 2, services, connection)
            let id = try #require(pane.stripModel.selectedID)
            let menu = try #require(pane.contextMenu(for: .tab(id, selection: [id])))
            let runs = Self.rows(menu).compactMap(ActionRegistry.menuRun(of:))
            #expect(!runs.isEmpty)
            var diverged: [String] = []
            for run in runs {
                #expect(services.registry.isBound(run.id), "\(run.id) is a menu row with no registered handler")
                #expect(run.target == ActionTargetRef(kind: .tab, id: id.rawValue), "\(run.id) targets \(String(describing: run.target))")
                let menuOK = ActionTargetReasons.canPerform(run.id, invocation: ActionInvocation(target: run.target, arguments: run.arguments), in: services.registry)
                let paletteOK = ActionTargetReasons.canPerform(run.id, invocation: ActionInvocation(arguments: run.arguments), in: services.registry)
                if menuOK != paletteOK { diverged.append("\(run.id) menu=\(menuOK) palette=\(paletteOK)") }
            }
            #expect(diverged.isEmpty, "rows that run differently from the menu and the palette: \(diverged)")
        }
    }
}
