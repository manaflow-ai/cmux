import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
@testable import CmuxNextTabs
import Foundation
import Testing

/// Every row of a pane tab's right-click menu, Copy ▸ and More ▸ included, on a terminal, a browser
/// and an agent chat tab: a shown row is either disabled with its reason, or a click does what it
/// says (Leo 2026-11-07: "I don't know if all the functionality for these work as well as they
/// should"). Each row runs from the menu the strip builds (`PaneController.contextMenu(for:)`),
/// clicked through its own target as AppKit does, on a fresh tab between two neighbours, against a
/// same-tree cmux-tui daemon. The rows of the top level and Copy ▸ check their exact effect; every
/// other row must change something a person can see (the tab, the strip, the layout, a window,
/// the pasteboard) or ask for what it needs.
@MainActor @Suite(.serialized, .timeLimit(.minutes(20)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct TabContextMenuActionsTests {
    enum Kind: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case terminal, browser, agent
        var testDescription: String { rawValue }
    }

    /// One shown row: where it sits, what it runs and the item to click.
    struct Row {
        let path: [String]
        let item: NSMenuItem
        var run: (id: ActionID, target: ActionTargetRef?, arguments: [String: ActionValue])? { ActionRegistry.menuRun(of: item) }
        var label: String { path.joined(separator: " ▸ ") }
        /// The same row in a menu built again: same action and arguments, else same titles.
        func matches(_ other: Row) -> Bool {
            if let run, let theirs = other.run { return run.id == theirs.id && run.arguments == theirs.arguments }
            return run == nil && other.run == nil && path == other.path
        }
    }

    /// What a person can see of the app around the right-clicked tab.
    struct World: Equatable {
        var subject: String
        var strip: [String]
        var tabs: Int
        var panes: Int
        var workspaces: Int
        var windows: Int
        var appWindows: Int
        var pasteboard: Int
        var asks: Int
    }

    /// The test's recorders: asks (the palette's argument steps), refusals and what the Copy rows copied.
    final class Recorder {
        var asks: [ActionID] = []
        var refusals: [String] = []
        var copied: [String] = []
        /// The window the rows run in, whatever window a move opens, and its pane the stages use.
        var window: WindowController?
        var pane: PaneController?
    }

    /// A fresh tab of `kind` with a tab on each side, in the window's first pane.
    struct Stage {
        let pane: PaneController
        let subject: StripTabID
        let left: StripTabID
        let right: StripTabID
    }

    // MARK: Harness

    private static func install(_ services: AppServices) -> Recorder {
        let recorder = Recorder()
        services.registry.copyText = { recorder.copied.append($0) }
        recorder.window = services.windows.active
        recorder.pane = services.windows.active?.focusedPane
        services.registry.argumentCollector = { id, _ in recorder.asks.append(id) }
        services.registry.argumentAsker = { id, _, _ in recorder.asks.append(id) }
        let previous = services.registry.refusalObserver
        services.registry.refusalObserver = { reason, quiet in
            recorder.refusals.append(reason)
            previous?(reason, quiet)
        }
        // An agent chat tab needs this Mac's install id (`AgentTabStore.open`).
        if services.agentTabs.localHost == nil { services.agentTabs.localHost = "install:tab-menu-test" }
        return recorder
    }

    private static func panes(_ recorder: Recorder) -> [PaneController] {
        (recorder.window?.workspaceContent?.panes.values).map { $0.sorted { $0.paneKey < $1.paneKey } } ?? []
    }

    /// The test pane back to one new terminal and every other pane of its workspace to no tab, so no row's
    /// effect (a pin, a group, a split) carries into the next row's stage.
    private static func reset(_ recorder: Recorder, _ connection: DaemonConnection) async throws -> PaneController {
        // The pane the window had focused, or (once a row closed it) the first pane left.
        if !panes(recorder).contains(where: { $0 === recorder.pane }) { recorder.pane = panes(recorder).first }
        let pane = try #require(recorder.pane, "the test window shows no pane")
        for other in panes(recorder) where other !== pane && !other.orderedIDs.isEmpty { other.close(other.orderedIDs) }
        let old = pane.orderedIDs
        _ = try await connection.newTab(in: pane.pane.handle)
        try await PinnedPageTests.until({ pane.orderedIDs.contains { !old.contains($0) && pane.tab($0) != nil } }, report: { "\(pane.orderedIDs)" })
        pane.close(old)
        try await PinnedPageTests.until({ pane.orderedIDs.count == 1 }, report: { "\(pane.orderedIDs)" })
        // Another pane's tab that will not close (an agent chat's dock) stays as it is: each row compares the
        // world before and after its click, so a pane that does not change is no row's effect.
        let others = { panes(recorder).filter { $0 !== pane }.flatMap(\.orderedIDs) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !others().isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        return pane
    }

    private static func pageFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tab-menu-\(UUID().uuidString.prefix(8)).html")
        try "<html><head><title>Menu page</title></head><body>menu</body></html>".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Opens a tab of `kind` in `pane` and returns its strip id once the strip and the store list it.
    private static func open(_ kind: Kind, in pane: PaneController, _ services: AppServices, _ connection: DaemonConnection) async throws -> StripTabID {
        let before = Set(pane.orderedIDs)
        let fresh = { pane.orderedIDs.first { !before.contains($0) && !ProvisionalTab.isProvisional($0.rawValue) } }
        switch kind {
        case .terminal:
            _ = try await connection.newTab(in: pane.pane.handle)
            try await PinnedPageTests.until({ fresh().flatMap { pane.tab($0) } != nil }, report: { "\(pane.orderedIDs)" })
        case .browser:
            let page = try pageFile()
            #expect(pane.newBrowserTab(url: page, engine: BrowserEngineTag.webkit.rawValue))
            try await PinnedPageTests.until({ fresh().flatMap { pane.tab($0) }?.kind == .browser },
                                            report: { "\(pane.orderedIDs) \(pane.pane.tabs.map(\.kind))" })
        case .agent:
            let created = try await services.agentTabs.open(in: pane.pane.handle, of: pane.daemon).value()
            try await PinnedPageTests.until({ pane.tab(StripTabID(created.key)) != nil && pane.orderedIDs.contains(StripTabID(created.key)) },
                                            report: { "\(created.key) \(pane.orderedIDs)" })
            return StripTabID(created.key)
        }
        return try #require(fresh())
    }

    private static func stage(_ kind: Kind, _ services: AppServices, _ connection: DaemonConnection, _ recorder: Recorder) async throws -> Stage {
        let pane = try await reset(recorder, connection)
        // A new tab lands beside the selected one: select each tab before opening its right neighbour.
        if let base = pane.orderedIDs.first { pane.select(base) }
        let subject = try await open(kind, in: pane, services, connection)
        pane.select(subject)
        _ = try await open(Kind.terminal, in: pane, services, connection)
        // The tabs keep their ids for a moment: a tab whose record is still being made changes its id.
        var order = pane.orderedIDs, steady = 0, polls = 0
        while steady < 5, polls < 100 {
            try await Task.sleep(for: .milliseconds(100))
            steady = pane.orderedIDs == order && services.locateTab(subject.rawValue) != nil ? steady + 1 : 0
            order = pane.orderedIDs
            polls += 1
        }
        if let at = order.firstIndex(of: subject), at == 0 || at == order.count - 1 {
            pane.move(subject, toPane: pane, index: 1)
            try await PinnedPageTests.until({ pane.orderedIDs.firstIndex(of: subject) == 1 }, report: { "\(pane.orderedIDs)" })
            order = pane.orderedIDs
        }
        let index = try #require(order.firstIndex(of: subject))
        try #require(index > 0 && index < order.count - 1, "the subject \(subject) is not between two tabs: \(order)")
        return Stage(pane: pane, subject: subject, left: order[index - 1], right: order[index + 1])
    }

    private static func menu(_ stage: Stage) -> NSMenu {
        stage.pane.contextMenu(for: .tab(stage.subject, selection: [stage.subject])) ?? NSMenu()
    }

    /// Every clickable row, each choices submenu by its first choice that is not the current one.
    static func rows(_ menu: NSMenu, path: [String] = []) -> [Row] {
        var rows: [Row] = []
        var choices: Set<ActionID> = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if let submenu = item.submenu {
                rows += Self.rows(submenu, path: path + [item.title])
                continue
            }
            let row = Row(path: path + [item.title], item: item)
            if let run = row.run, !run.arguments.isEmpty {
                // A choice that sets nothing ("None" on a tab with none) has nothing to show.
                let sets = run.arguments.values.allSatisfy { !["", "none", "default"].contains($0.stringValue?.lowercased() ?? "set") }
                guard item.state != .on, sets, choices.insert(run.id).inserted else { continue }
            }
            rows.append(row)
        }
        return rows
    }

    /// The row's state as a menu shows it: enabled, else the reason it gives.
    private static func validate(_ item: NSMenuItem) -> (enabled: Bool, reason: String?) {
        let enabled = (item.target as? NSMenuItemValidation)?.validateMenuItem(item) ?? item.isEnabled
        return (enabled && !item.isHidden, item.toolTip)
    }

    private static func click(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func world(_ stage: Stage, _ services: AppServices, _ recorder: Recorder) -> World {
        let located = services.locateTab(stage.subject.rawValue)
        let tab = located?.0
        var parts: [String] = [located?.1.id ?? "-"]
        parts.append(tab.map { "\($0.pinned) \($0.markedUnread)" } ?? "-")
        parts.append(tab?.tabGroup?.rawValue ?? "-")
        parts.append(tab?.name ?? "-")
        parts.append(tab?.userIcon ?? "-")
        parts.append(tab?.url ?? "-")
        parts.append(tab?.zoom.map { "\($0)" } ?? "-")
        parts.append(tab?.emulation.map { "\($0)" } ?? "-")
        parts.append(tab.flatMap { services.themes.ownValue(.tint, of: .tab(stage.pane, $0)) } ?? "-")
        let subject = parts.joined(separator: "|")
        let workspaces = services.machines.allWorkspaces.map(\.0)
        return World(subject: subject, strip: stage.pane.orderedIDs.map(\.rawValue),
                     tabs: workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).count,
                     panes: workspaces.flatMap(\.screens).flatMap(\.panes).count, workspaces: workspaces.count,
                     windows: services.windows.controllers.count, appWindows: NSApp.windows.filter(\.isVisible).count,
                     pasteboard: recorder.copied.count, asks: recorder.asks.count)
    }

    // MARK: Expectations

    /// What the row must have done, beyond changing something: nil when it did, else what is wrong.
    private static func check(_ id: ActionID, _ kind: Kind, _ stage: Stage, _ services: AppServices, _ recorder: Recorder) -> String? {
        let pane = stage.pane, order = pane.orderedIDs
        let tab = pane.tab(stage.subject)
        let copied = recorder.copied.last ?? ""
        switch id {
        case "newTab.toRight":
            guard let index = order.firstIndex(of: stage.subject), index + 1 < order.count, order[index + 1] != stage.right else {
                return "no new tab right after the tab: \(order)"
            }
        case "duplicateTab":
            guard let index = order.firstIndex(of: stage.subject), index + 1 < order.count, order[index + 1] != stage.right else {
                return "no duplicate right after the tab: \(order)"
            }
            let copy = order[index + 1]
            // In a group the copy stays in it, right after the original (Chrome's Duplicate).
            if let group = tab?.tabGroup, pane.tab(copy)?.tabGroup != group { return "the duplicate right after the tab is not in its group \(group): \(order)" }
            switch kind {
            case .terminal: if pane.tab(copy)?.kind != .pty { return "the duplicate is a \(String(describing: pane.tab(copy)?.kind)), not a terminal" }
            case .browser: if pane.tab(copy)?.kind != .browser { return "the duplicate is a \(String(describing: pane.tab(copy)?.kind)), not a browser" }
            case .agent: if !services.agentTabs.isAgentTab(copy.rawValue) { return "the duplicate is not an agent chat" }
            }
        case "palette.toggleTabPin":
            if tab?.pinned != true { return "the tab is not pinned" }
        case "tabGroup.create":
            if tab?.tabGroup == nil { return "the tab is in no group" }
        case "tabGroup.addTab":
            // It asks for a group from the open ones: with none, the person gets an empty list.
            let groups = services.machines.allWorkspaces.map(\.0).flatMap(\.screens).flatMap(\.panes).flatMap(\.tabGroups)
            if groups.allSatisfy({ $0.id == tab?.tabGroup }) { return "asked for a group with no other group open to pick" }
        case "tabGroup.removeTab":
            if tab?.tabGroup != nil { return "the tab is still in its group" }
        case "closeTab":
            if order.contains(stage.subject) { return "the tab is still open" }
        case "closeOtherTabsInPane":
            if order != [stage.subject] { return "other tabs are still open: \(order)" }
        case "closeTabsToRight":
            if order.contains(stage.right) || !order.contains(stage.left) || !order.contains(stage.subject) { return "closed the wrong tabs: \(order)" }
        case "closeTabsToLeft":
            if order.contains(stage.left) || !order.contains(stage.right) || !order.contains(stage.subject) { return "closed the wrong tabs: \(order)" }
        case "palette.copySurfaceID":
            guard let tab else { return "the tab is gone" }
            if copied != "surface_id=\(tab.id)" { return "copied \(copied.debugDescription)" }
        case "palette.copyPaneID":
            if copied != "pane_id=\(pane.pane.id)" { return "copied \(copied.debugDescription)" }
        case "palette.copyIdentifiers":
            guard let tab else { return "the tab is gone" }
            if !copied.contains("pane_id=\(pane.pane.id)") || !copied.contains("surface_id=\(tab.id)") { return "copied \(copied.debugDescription)" }
        case "palette.copySurfaceLink", "palette.copyPaneLink":
            if !copied.contains("://") { return "copied \(copied.debugDescription), not a link" }
        case "agentChat.copyIdentifier":
            if copied.isEmpty { return "copied nothing" }
        case "renameTab":
            if !recorder.asks.contains("renameTab") { return "no name was asked for" }
        case "palette.clearTabName":
            if tab?.name != nil { return "the tab still has its name \(tab?.name ?? "")" }
        default:
            break
        }
        return nil
    }

    /// Rows whose effect lives where this harness cannot see it (a page's audio, a reload): a click must still not be refused.
    private static let unobservable: Set<ActionID> = ["reloadTab", "toggleTabAudioMute", "tab.muteOtherAudio"]

    /// Rows that need what a test host has not: a window on screen, Home, Settings. They are clicked and
    /// reported, not judged.
    private static let needsTheRealApp: [String: String] = [
        "home.messageAbout": "needs Home, which a test window has not",
        "tab.showResources": "anchors its card on a window on screen",
        "tab.setIcon": "anchors its picker on the tab's chip on screen",
        "Customize Menu…": "opens Settings, which this harness does not load",
    ]

    /// Readies the subject for a row that needs a state first (Clear Tab Name needs a name).
    private static func prepare(_ id: ActionID, _ stage: Stage, _ connection: DaemonConnection) async throws {
        guard id == "palette.clearTabName", let tab = stage.pane.tab(stage.subject) else { return }
        try await connection.renameTab(tab.surface, to: "Named for the menu test")
        try await PinnedPageTests.until({ stage.pane.tab(stage.subject)?.name != nil })
    }

    /// What a test does to a fresh stage before its rows run (pin the tab, group it, make its chat another Mac's).
    typealias Setup = @MainActor (Stage, AppServices, DaemonConnection) async throws -> Void

    /// One row on a fresh stage (readied by `setup`): nil when it works, else what is wrong.
    private static func exercise(_ row: Row, _ kind: Kind, _ services: AppServices, _ connection: DaemonConnection,
                                 _ recorder: Recorder, setup: Setup? = nil) async throws -> (outcome: String, failure: String?) {
        let stage = try await Self.stage(kind, services, connection, recorder)
        try await setup?(stage, services, connection)
        if let id = row.run?.id { try await prepare(id, stage, connection) }
        let limit = needsTheRealApp[row.run?.id.rawValue ?? row.label]
        guard let current = Self.rows(Self.menu(stage)).first(where: row.matches) else {
            return ("missing", "the row is not in the menu of a fresh \(kind.rawValue) tab")
        }
        let state = validate(current.item)
        guard state.enabled else {
            return state.reason == nil ? ("disabled", "disabled with no reason") : ("disabled: \(state.reason ?? "")", nil)
        }
        let before = Self.world(stage, services, recorder)
        let refusals = recorder.refusals.count
        click(current.item)
        if let limit {
            try await Task.sleep(for: .milliseconds(300))
            return ("not checked here: \(limit)", nil)
        }
        let id = current.run?.id
        let changed = { Self.world(stage, services, recorder) != before }
        let done = {
            changed() && (id.map { check($0, kind, stage, services, recorder) == nil } ?? true)
        }
        let deadline = ContinuousClock.now + .seconds(id.map(unobservable.contains) == true ? 1 : 8)
        while !done(), recorder.refusals.count == refusals, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        if recorder.refusals.count > refusals { return ("refused", "enabled, but the click was refused: \(recorder.refusals[refusals])") }
        if let id, unobservable.contains(id) { return ("ran", nil) }
        guard changed() else { return ("no effect", "enabled, but the click changed nothing") }
        if let id, let wrong = check(id, kind, stage, services, recorder) { return ("wrong effect", wrong) }
        if id == "tabGroup.addTab", let run = current.run, let failure = try await pick(run, stage, services, recorder) {
            return ("refused the pick", failure)
        }
        return ("works", nil)
    }

    /// Add Tab to Group… asked for a group: the first one it could list is picked, as the palette's step does. Nil when
    /// the tab joins it, else what is wrong (a row that asks and then refuses the answer is clickable and then refuses).
    private static func pick(_ run: (id: ActionID, target: ActionTargetRef?, arguments: [String: ActionValue]), _ stage: Stage,
                             _ services: AppServices, _ recorder: Recorder) async throws -> String? {
        guard case let (tab, pane)? = services.locateTab(stage.subject.rawValue),
              let group = TabGroupWrites.joinable(by: tab, in: services.daemon(for: pane).store).first else { return "no group to pick" }
        let refusals = recorder.refusals.count
        var arguments = run.arguments
        arguments["group"] = .target(ActionTargetRef(kind: .tabGroup, id: group.id.rawValue))
        _ = services.registry.perform(run.id, invocation: ActionInvocation(target: run.target, arguments: arguments))
        let joined = { services.locateTab(stage.subject.rawValue)?.0.tabGroup == group.id }
        let deadline = ContinuousClock.now + .seconds(8)
        while !joined(), recorder.refusals.count == refusals, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        if recorder.refusals.count > refusals { return "asked for a group, then refused the pick: \(recorder.refusals[refusals])" }
        return joined() ? nil : "the tab did not join the group it was given"
    }

    /// Every row of `ids` in the menu of a fresh `kind` tab readied by `setup`; the failures, and the report.
    private static func exercise(_ ids: Set<ActionID>, of kind: Kind, setup: @escaping Setup, _ services: AppServices,
                                 _ connection: DaemonConnection, _ recorder: Recorder) async throws -> (failures: [String], report: [String]) {
        let stage = try await Self.stage(kind, services, connection, recorder)
        try await setup(stage, services, connection)
        let rows = Self.rows(Self.menu(stage)).filter { $0.run.map { ids.contains($0.id) } ?? false }
        try #require(!rows.isEmpty, "the menu shows none of \(ids)")
        var failures: [String] = [], report: [String] = []
        for row in rows {
            let (outcome, failure) = try await Self.exercise(row, kind, services, connection, recorder, setup: setup)
            report.append("\(kind.rawValue) | \(row.label) | \(row.run?.id.rawValue ?? "-") | \(outcome)")
            if let failure { failures.append("\(row.label): \(failure)") }
        }
        print("tab-menu-rows:\n" + report.joined(separator: "\n"))
        return (failures, report)
    }

    /// The tab pinned, beside a group of the left tab it could join if it were not pinned.
    private static let pinBesideAGroup: Setup = { stage, services, connection in
        #expect(services.registry.perform("tabGroup.create", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: stage.left.rawValue))))
        try await PinnedPageTests.until({ stage.pane.tab(stage.left)?.tabGroup != nil })
        let tab = try #require(stage.pane.tab(stage.subject))
        _ = try await connection.setTabPinned(tab.surface, true)
        try await PinnedPageTests.until({ stage.pane.tab(stage.subject)?.pinned == true })
    }

    /// The agent chat is another Mac's: this Mac's install id changes under it, so the chat's host is no longer this
    /// Mac (a fresh id each time, as the next stage's chat is made under the one before).
    private static let chatOfAnotherMac: Setup = { stage, services, _ in
        let host = try #require(services.agentTabs.lookup(stage.subject.rawValue)?.record.host)
        services.agentTabs.localHost = "install:another-mac-\(UUID().uuidString.prefix(8))"
        #expect(services.agentTabs.lookup(stage.subject.rawValue)?.record.host == host)
    }

    /// A group of the left tab, the tab and the right tab, in that order (each joins at the end).
    private static let groupAllThree: Setup = { stage, services, _ in
        let registry = services.registry
        #expect(registry.perform("tabGroup.create", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: stage.left.rawValue))))
        try await PinnedPageTests.until({ stage.pane.tab(stage.left)?.tabGroup != nil })
        let group = try #require(stage.pane.tab(stage.left)?.tabGroup)
        for id in [stage.subject, stage.right] {
            #expect(registry.perform("tabGroup.addTab", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .tab, id: id.rawValue),
                arguments: ["group": .target(ActionTargetRef(kind: .tabGroup, id: group.rawValue))])))
            try await PinnedPageTests.until({ stage.pane.tab(id)?.tabGroup == group }, report: { "\(id) is not in \(group)" })
        }
        try await PinnedPageTests.until({ stage.pane.orderedIDs.prefix(3) == [stage.left, stage.subject, stage.right] },
                                        report: { "\(stage.pane.orderedIDs)" })
    }

    // MARK: Tests

    /// The top level of a terminal tab's menu, in the order Leo's screenshot shows it.
    @Test func aTerminalTabsMenuShowsTheRowsInLeosScreenshot() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let recorder = Self.install(services)
            let stage = try await Self.stage(.terminal, services, connection, recorder)
            let top = Self.menu(stage).items.filter { !$0.isSeparatorItem && !$0.isHidden }.map { ActionRegistry.menuRun(of: $0)?.id.rawValue ?? $0.title }
            let expected = ["newTab.toRight", "tabGroup.create", "tabGroup.addTab", "duplicateTab", "palette.toggleTabPin",
                            "closeTab", "closeOtherTabsInPane", "closeTabsToRight"]
            #expect(Array(top.prefix(expected.count)) == expected, "\(top)")
            #expect(top.count == expected.count + 3, "after Close Tabs to the Right: Copy, More, Customize Menu…; got \(top)")
        }
    }

    /// Every row of the tab's menu, Copy ▸ and More ▸ included, on a fresh tab of `kind`.
    @Test(arguments: Kind.allCases)
    func everyRowOfTheTabMenuWorksOrSaysWhy(_ kind: Kind) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let recorder = Self.install(services)
            let rows = Self.rows(Self.menu(try await Self.stage(kind, services, connection, recorder)))
            try #require(!rows.isEmpty, "the \(kind.rawValue) tab has no menu")
            var report: [String] = []
            var failures: [String] = []
            for row in rows {
                let (outcome, failure) = try await Self.exercise(row, kind, services, connection, recorder)
                report.append("\(kind.rawValue) | \(row.label) | \(row.run?.id.rawValue ?? "-") | \(outcome)")
                if let failure { failures.append("\(row.label): \(failure)") }
            }
            print("tab-menu-rows:\n" + report.joined(separator: "\n"))
            #expect(failures.isEmpty, "\(kind.rawValue) tab menu rows that do not work:\n\(failures.joined(separator: "\n"))\n\nall rows:\n\(report.joined(separator: "\n"))")
        }
    }

    /// Add Tab to Group… and New Tab Group on a pinned tab (Leo 2026-11-07, ask-b8d1047179): a pinned tab never joins a
    /// group, so each row is disabled with the reason, never clickable and then refused.
    @Test func theGroupRowsOfAPinnedTabWorkOrSayWhy() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let recorder = Self.install(services)
            let (failures, report) = try await Self.exercise(["tabGroup.create", "tabGroup.addTab"], of: .terminal, setup: Self.pinBesideAGroup,
                                                             services, connection, recorder)
            #expect(report.contains { $0.contains("tabGroup.addTab") }, "a pinned tab's menu has no Add Tab to Group…: \(report)")
            #expect(failures.isEmpty, "pinned tab group rows that do not work:\n\(failures.joined(separator: "\n"))\n\nall rows:\n\(report.joined(separator: "\n"))")
        }
    }

    /// Duplicate Tab on a chat another Mac runs: its session never leaves that Mac, so the row is disabled with the
    /// reason, never clickable and then refused.
    @Test func duplicateTabOnAnotherMacsChatWorksOrSaysWhy() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let recorder = Self.install(services)
            let (failures, report) = try await Self.exercise(["duplicateTab"], of: .agent, setup: Self.chatOfAnotherMac,
                                                             services, connection, recorder)
            #expect(failures.isEmpty, "Duplicate Tab on another Mac's chat:\n\(failures.joined(separator: "\n"))\n\nall rows:\n\(report.joined(separator: "\n"))")
        }
    }

    /// Duplicate Tab on a tab inside a group: the copy lands right after the tab, in its group, not at the group's end.
    @Test(arguments: Kind.allCases)
    func duplicateTabInAGroupLandsRightAfterTheTab(_ kind: Kind) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let recorder = Self.install(services)
            let (failures, report) = try await Self.exercise(["duplicateTab"], of: kind, setup: Self.groupAllThree,
                                                             services, connection, recorder)
            #expect(failures.isEmpty, "Duplicate Tab in a group:\n\(failures.joined(separator: "\n"))\n\nall rows:\n\(report.joined(separator: "\n"))")
        }
    }

    /// Remove Tab from Group shows on a grouped tab and takes it out; Add Tab to Group… asks for
    /// a group when one exists, and the group it is given takes the tab.
    @Test func theGroupRowsMoveTheTabInAndOutOfAGroup() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let recorder = Self.install(services)
            let stage = try await Self.stage(.terminal, services, connection, recorder)
            let registry = services.registry
            // A group of the left tab: the subject can join it.
            #expect(registry.perform("tabGroup.create", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: stage.left.rawValue))))
            try await PinnedPageTests.until({ stage.pane.tab(stage.left)?.tabGroup != nil })
            let group = try #require(stage.pane.tab(stage.left)?.tabGroup)
            var add = try #require(Self.rows(Self.menu(stage)).first { $0.run?.id == "tabGroup.addTab" })
            #expect(Self.validate(add.item).enabled, "Add Tab to Group… is disabled with a group to join: \(add.item.toolTip ?? "")")
            Self.click(add.item)
            #expect(recorder.asks.contains("tabGroup.addTab"), "Add Tab to Group… asked for no group")
            #expect(registry.perform("tabGroup.addTab", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .tab, id: stage.subject.rawValue),
                arguments: ["group": .target(ActionTargetRef(kind: .tabGroup, id: group.rawValue))])))
            try await PinnedPageTests.until({ stage.pane.tab(stage.subject)?.tabGroup == group }, report: { "\(String(describing: stage.pane.tab(stage.subject)?.tabGroup))" })

            let remove = try #require(Self.rows(Self.menu(stage)).first { $0.run?.id == "tabGroup.removeTab" }, "a grouped tab's menu has no Remove Tab from Group")
            #expect(Self.validate(remove.item).enabled)
            Self.click(remove.item)
            try await PinnedPageTests.until({ stage.pane.tab(stage.subject)?.tabGroup == nil }, report: { "the tab is still in its group" })
            add = try #require(Self.rows(Self.menu(stage)).first { $0.run?.id == "tabGroup.addTab" })
            #expect(Self.validate(add.item).enabled, "the tab left a group it can join again")
        }
    }

    /// Pin Tab reads Unpin Tab on a pinned tab, and unpins it.
    @Test func pinTabReadsUnpinTabOnAPinnedTabAndUnpinsIt() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let recorder = Self.install(services)
            let stage = try await Self.stage(.terminal, services, connection, recorder)
            let pin = try #require(Self.rows(Self.menu(stage)).first { $0.run?.id == "palette.toggleTabPin" })
            Self.click(pin.item)
            try await PinnedPageTests.until({ stage.pane.tab(stage.subject)?.pinned == true })
            let unpin = try #require(Self.rows(Self.menu(stage)).first { $0.run?.id == "palette.toggleTabPin" })
            #expect(unpin.item.title != pin.item.title, "the pinned tab's row still reads \(pin.item.title)")
            Self.click(unpin.item)
            try await PinnedPageTests.until({ stage.pane.tab(stage.subject)?.pinned == false })
        }
    }

    /// Close Other Tabs keeps a pinned tab (the row's own promise, "pinned tabs stay").
    @Test func closeOtherTabsKeepsPinnedTabs() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let recorder = Self.install(services)
            let stage = try await Self.stage(.terminal, services, connection, recorder)
            let left = try #require(stage.pane.tab(stage.left))
            _ = try await connection.setTabPinned(left.surface, true)
            try await PinnedPageTests.until({ stage.pane.tab(stage.left)?.pinned == true })
            let row = try #require(Self.rows(Self.menu(stage)).first { $0.run?.id == "closeOtherTabsInPane" })
            Self.click(row.item)
            try await PinnedPageTests.until({ !stage.pane.orderedIDs.contains(stage.right) }, report: { "\(stage.pane.orderedIDs)" })
            #expect(Set(stage.pane.orderedIDs) == [stage.left, stage.subject], "\(stage.pane.orderedIDs)")
        }
    }
}
