import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTabs
import os

/// A pane's tab bar trailing controls: the actions pinned as buttons (`tabs.toolbarButtons`, none by default;
/// Lawrence 2026-10-12), a zoomed pane's Exit Zoom, then the pane's actions menu "…" (Leo 2026-10-12; back after
/// 2026-11-13's removal, user 2026-11-16: "tabbar right side … is missing now like the one with pane actions"). The
/// menu is the strip plus's (a terminal, a browser, an agent chat, … in this pane), then the splits and zoom not
/// pinned, Search Tabs, then Show in Tab Bar, which pins or unpins one. On a terminal running an agent session it leads
/// with Switch to Chat (user 2026-11-20: "we used to have an additional button that will let u switch from terminal to
/// chat ui; we should add that back, but inside the 3 dots thing"); the toolbar's `>_ | bubble` pair stays out. A
/// chat's pane draws its own tools (acpmux header/ChatHeaderTools.tsx), whose ⋮ offers Switch to Terminal.
@MainActor
final class PaneToolbar: PaneControlsRefreshing {
    /// What the selected tab is, for its own actions; nil is a chat: no pins and no "…".
    enum Kind: Hashable, Sendable {
        case newTab, terminal, browser, other
    }

    /// What the bar follows: the selected tab, its kind, whether the pane is zoomed and the pins.
    struct State: Equatable, Sendable {
        var target: String?
        var kind: Kind?
        var zoomed = false
        var pinned: [String] = []
        /// What every tab of the pane that can show pins is: the bar keeps their room whichever is
        /// selected, so a selection never changes the strip's width (Lawrence 2026-10-19).
        var paneKinds: Set<Kind> = []
        /// The strip selects a tab the store no longer lists (a provisional tab the store's tab
        /// just replaced): the selection follows on the strip's next apply, so the bar keeps what
        /// it shows. Hiding the pins for that frame gave their width to the strip, which laid out
        /// every tab again at once (10 tabs, cx-codh2).
        var behind = false
        var nativeOwnerID: ObjectIdentifier?
        var nativeItems: [PaneTabRowTool] = []
        var nativeEnabled = false
    }

    let view: PaneToolbarView
    private let registry: () -> ActionRegistry?
    private let paneTarget: ActionTargetRef?
    private let machineID: () -> String?
    static let creationActions: [ActionID] = ["newSurface", "openBrowser"]
    /// The shown content's own rows (``PaneMoreMenuContributing``: the docked Home's Chief Actions and
    /// Subagents), first in "…" and the selected tab's right-click.
    private let contentMenu: () -> [NSMenuItem]
    /// The selected tab's own switch, Switch to Chat or Switch to Terminal on half of a terminal and chat pair
    /// (``PaneController/terminalChatSwitchRows(tab:model:)``), read when "…" opens; none for any other tab.
    private let switchRows: (String) -> [NSMenuItem]
    private(set) var target: String?
    private(set) var kind: Kind?
    private(set) var zoomed = false
    private(set) var pinned: [String] = []
    /// Writes the pinned list (`tabs.toolbarButtons`); every pane follows the file.
    var writePinned: (PaneToolbarButtonsSetting) -> Void = { _ in }
    private var observation: Task<Void, Never>?
    private var refreshCurrent: (() -> Void)?

    init(registry: @escaping () -> ActionRegistry?, paneTarget: ActionTargetRef? = nil,
         contentMenu: @escaping () -> [NSMenuItem] = { [] }, switchRows: @escaping (String) -> [NSMenuItem] = { _ in [] },
         machineID: @escaping () -> String? = { nil }, view: PaneToolbarView = PaneToolbarView()) {
        (self.view, self.registry) = (view, registry)
        self.machineID = machineID
        self.paneTarget = paneTarget
        self.contentMenu = contentMenu
        self.switchRows = switchRows
        view.moreMenu = { [weak self] in self?.moreMenu() }
        view.onPerform = { [weak self] id in self?.perform(ActionID(rawValue: id)) }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        observation?.cancel()
    }

    /// The pane's trailing controls: follow its selected tab and the pane's zoom. `view`: its buttons, made ahead (a pane spare's).
    convenience init(pane: PaneController, view: PaneToolbarView? = nil) {
        let services = pane.services
        self.init(registry: { [weak services] in services?.registry },
                  paneTarget: ActionTargetRef(kind: .pane, id: pane.paneKey),
                  contentMenu: { [weak pane] in (pane?.view.content as? PaneMoreMenuContributing)?.paneMoreMenuItems() ?? [] },
                  switchRows: { [weak pane] id in pane.flatMap { pane in pane.tab(StripTabID(id)).map { pane.terminalChatSwitchRows(tab: id, model: $0) } } ?? [] },
                  machineID: { [weak pane] in pane?.daemon.machineID }, view: view ?? PaneToolbarView())
        writePinned = { [weak services] next in
            guard let settings = services?.settings else { return }
            // task-owner: one write; the menu item's gesture is the user's (SettingWriter.currentRun)
            Task {
                do { try await settings.setSetting(at: PaneToolbarButtonsSetting.configPath, to: next.configValue, by: .currentRun()) } catch {
                    Logger(subsystem: "com.cmuxterm.app.next", category: "pane-toolbar").error("tabs.toolbarButtons write failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        refreshCurrent = { [weak self, weak pane] in
            if let self, let pane { self.apply(Self.state(pane), owner: pane.view.nativeToolOwner) }
        }
        let (first, later) = ObservationStream.current({ [weak pane] in pane.map(Self.state) })
        if let first { apply(first, owner: pane.view.nativeToolOwner) } // now: a relaunched pane's first frame had a 0 pt toolbar
        // task-owner: lives as long as the pane's view; event-driven (Observation)
        observation = Task { [weak self, weak pane] in
            for await state in later {
                guard let self, let state, let pane else { return }
                apply(state, owner: pane.view.nativeToolOwner)
            }
        }
    }

    /// Rebinds controls immediately after the pane changes content ownership.
    func refresh() { refreshCurrent?() }

    /// Apply one ownership snapshot; a retained menu can never retarget its IDs to another page.
    func apply(_ state: State, owner: PaneNativeToolOwner) {
        let model = owner.model
        guard state.nativeOwnerID == model.map(ObjectIdentifier.init) else { return }
        view.onNativeTool = { [weak model, weak owner] id, menuItemID in
            guard let model, owner?.model === model, model.tabRow.nativeToolsEnabled else { return }
            model.onTabRowToolInvoked?(id, menuItemID)
        }
        view.onNativeToolURL = { [weak model, weak owner, weak view] id, menuItemID, url in
            guard let model, let view, owner?.model === model, model.tabRow.nativeToolsEnabled else { return }
            view.openURL(url)
            model.onTabRowToolInvoked?(id, menuItemID)
        }
        update(target: state.behind ? target : state.target, kind: state.behind ? kind : state.kind,
               zoomed: state.zoomed, pinned: state.pinned, paneKinds: state.paneKinds, nativeItems: state.nativeItems, nativeEnabled: state.nativeEnabled)
    }

    private static func state(_ pane: PaneController) -> State {
        let displayedModel = pane.view.nativeToolOwner.model
        let pinned = pane.services.settings.map { PaneToolbarButtonsSetting.current($0).pinned } ?? []
        let resolver = TabTitleResolver(services: pane.services)
        let paneKinds = Set(pane.pane.tabs.compactMap { kind($0, isNewTabPage: resolver.isNewTabPage($0)) })
        guard let key = pane.stripModel.selectedID?.rawValue else { return State(zoomed: pane.stripModel.zoomsSelected, pinned: pinned, paneKinds: paneKinds, nativeOwnerID: displayedModel.map(ObjectIdentifier.init), nativeItems: displayedModel?.tabRowTools ?? [], nativeEnabled: displayedModel?.tabRow.nativeToolsEnabled == true) }
        guard let tab = pane.pane.tabs.first(where: { $0.id == key }) else {
            // A window's own page or browser tab is never in the store: no pins, not a stale bar.
            let local = key.hasPrefix(LocalPageTab.prefix) || key.hasPrefix(LocalBrowserTab.prefix)
            return State(zoomed: pane.stripModel.zoomsSelected, pinned: pinned, paneKinds: paneKinds, behind: !local, nativeOwnerID: displayedModel.map(ObjectIdentifier.init), nativeItems: displayedModel?.tabRowTools ?? [], nativeEnabled: displayedModel?.tabRow.nativeToolsEnabled == true)
        }
        return State(target: key, kind: kind(tab, isNewTabPage: resolver.isNewTabPage(tab)), zoomed: pane.stripModel.zoomsSelected, pinned: pinned, paneKinds: paneKinds, nativeOwnerID: displayedModel.map(ObjectIdentifier.init), nativeItems: displayedModel?.tabRowTools ?? [], nativeEnabled: displayedModel?.tabRow.nativeToolsEnabled == true)
    }

    static func kind(_ tab: TabModel, isNewTabPage: Bool) -> Kind? {
        if tab.agentSession != nil { return isNewTabPage ? .newTab : nil }
        if tab.page != nil { return .other }
        switch tab.kind {
        case .pty, .remoteTerminal: return .terminal
        case .browser: return .browser
        case .conversation: return nil
        case .other: return .other
        }
    }

    /// The splits, the tab's own actions for `kind`, then the pane's zoom.
    static func actions(_ kind: Kind) -> [ActionID] {
        let own: [ActionID] = switch kind {
        case .newTab: ["openDiffViewer", "file.open", "agentPane.searchChats"]
        case .terminal: ["openDiffViewer", "file.open"]
        case .browser, .other: []
        }
        return ["splitRight", "splitDown"] + own + [zoom]
    }

    static let zoom: ActionID = "toggleSplitZoom", search: ActionID = "tab.search"

    private static let overflowNewTabTrimmedActions: Set<ActionID> = ["browserProfile.newTab", "newTab.page"]
    private static let overflowTabTrimmedActions: Set<ActionID> = ["openDiffViewer", "file.open", "agentPane.searchChats"]

    /// Shows the `pinned` actions tab `target` of `kind` can run and "…" (nil kind: none); "…" lit, with the Exit Zoom
    /// button left of it, while the pane is zoomed. `paneKinds`: the kinds of every tab in the pane, whichever is selected.
    func update(target: String?, kind: Kind?, zoomed: Bool = false, pinned: [String] = [], paneKinds: Set<Kind> = [], nativeItems: [PaneTabRowTool] = [], nativeEnabled: Bool = ChromeTunables.nativeRowTools.value) {
        self.target = target
        self.kind = kind
        self.zoomed = zoomed
        self.pinned = pinned
        let shown = target != nil && kind != nil
        // The room the bar keeps: "…" and the most pins any tab of the pane shows, so selecting a tab without
        // "…" (a chat, a window's own page) or fewer pins moves no tab.
        let kinds = kind.map { paneKinds.union([$0]) } ?? paneKinds
        let reservedPins = kinds.map { kind in pinned.count(where: { Self.actions(kind).contains(ActionID(rawValue: $0)) }) }.max() ?? 0
        let buttons = shownButtons()
        // The new-terminal and new-browser buttons are not shown: the + offers them (Lawrence 2026-10-27: too many buttons).
        let nativeTools = nativeEnabled ? nativeItems : []
        view.show(buttons.compactMap(item), more: shown, lit: zoomed && shown, zoomed: zoomed,
                  reserving: kinds.isEmpty ? max(reservedPins, buttons.count) : max(reservedPins, buttons.count) + 1, nativeItems: nativeTools)
    }

    /// The pinned actions the tab can run, in the user's order, as buttons.
    func shownPins() -> [ActionID] { pinned.map(ActionID.init(rawValue:)).filter(tabActions().contains) }

    /// The buttons: the pins. While the pane is zoomed a pinned zoom gives way to the bar's one
    /// Exit Zoom button, so the pane shows one zoom mark, never two.
    func shownButtons() -> [ActionID] { zoomed ? shownPins().filter { $0 != Self.zoom } : shownPins() }

    /// A pinned action's button: the New Tab page's tool symbols (cx-kk7lm), a zoomed pane's lit zoom.
    private func item(_ id: ActionID) -> PaneToolbarItem? {
        guard let registry = registry(), let descriptor = registry.descriptor(for: id) else { return nil }
        let title = descriptor.title.hasSuffix("…") ? String(descriptor.title.dropLast()) : descriptor.title
        let lit = zoomed && id == Self.zoom
        let symbols: [ActionID: String] = ["openDiffViewer": "plusminus", "file.open": "folder", "agentPane.searchChats": "bubble.left.and.text.bubble.right"]
        return PaneToolbarItem(id: id.rawValue, title: title, symbol: lit ? "arrow.down.right.and.arrow.up.left" : symbols[id] ?? descriptor.symbol,
                               shortcut: registry.shortcutDisplay(for: id), lit: lit, alwaysVisible: Self.creationActions.contains(id))
    }

    private func perform(_ id: ActionID) {
        if Self.creationActions.contains(id), let paneTarget {
            _ = registry()?.perform(id, invocation: ActionInvocation(target: paneTarget, origin: .user).onMachine(machineID()))
            return
        }
        guard let invocation = tabInvocation() else { return }
        _ = registry()?.perform(id, invocation: invocation)
    }

    private func tabInvocation() -> ActionInvocation? { target.map { ActionInvocation(target: ActionTargetRef(kind: .tab, id: $0), origin: .user).onMachine(machineID()) } }

    /// The tab's actions that can be pinned: those it can run.
    func tabActions() -> [ActionID] {
        guard let registry = registry(), let invocation = tabInvocation(), let kind else { return [] }
        return Self.actions(kind).filter { ActionTargetReasons.canPerform($0, invocation: invocation, in: registry) }
    }

    /// "…": the tab's own switch (Switch to Chat), the content's own rows (the Chief's), what opens in the pane, the
    /// actions without a button with their keys, Search Tabs, then Show in Tab Bar.
    private func moreMenu() -> NSMenu? {
        guard let registry = registry(), let target else { return nil }
        let menu = paneTarget.map { registry.makePaneMoreMenu(pane: $0, trimming: Self.overflowNewTabTrimmedActions, machineID: machineID()) } ?? NSMenu()
        view.layoutSubtreeIfNeeded()
        let buttons = zip(view.items, view.buttons).compactMap { item, button in button.isHidden ? nil : ActionID(rawValue: item.id) }
        let rows = tabActions().filter { !buttons.contains($0) && (!Self.overflowTabTrimmedActions.contains($0) || pinned.contains($0.rawValue)) }
        let sections = [switchRows(target), contentMenu(), menu.items, Self.detach(registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: target),
                                                                                  entries: rows.map { .action($0) }, machineID: machineID())),
                        // Search Tabs runs with no tab target: a tab target only reveals that tab.
                        Self.detach(registry.makeContextMenu(for: .tab, entries: [.action(Self.search)])), [showInTabBarItem(registry: registry)]]
        menu.removeAllItems()
        for section in sections where !section.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
        // Every row in the theme's highlight, like the sidebar's ⋮ menus and the strip's plus.
        return menu.themeRows(in: view.themeScope.fullStrength)
    }

    /// The shown content's own rows (the docked Home's Chief Actions and Subagents), fresh each call.
    func contentRows() -> [NSMenuItem] { contentMenu() }

    /// `menu`'s rows, taken out of it so another menu can hold them.
    private static func detach(_ menu: NSMenu) -> [NSMenuItem] {
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    /// Show in Tab Bar: the selected kind's controls, plus existing pins so they can be unpinned.
    private func showInTabBarItem(registry: ActionRegistry) -> NSMenuItem {
        let item = NSMenuItem(title: PaneToolbarStrings.showInTabBar, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: PaneToolbarStrings.showInTabBar)
        let setting = PaneToolbarButtonsSetting(pinned: pinned)
        let available = Set(kind.map(Self.actions) ?? [])
        for id in PaneToolbarButtonsSetting.values where available.contains(ActionID(rawValue: id)) || pinned.contains(id) {
            guard let descriptor = registry.descriptor(for: ActionID(rawValue: id)) else { continue }
            let row = NSMenuItem(title: descriptor.title, action: #selector(ActionMenuClosure.run), keyEquivalent: "")
            row.state = pinned.contains(id) ? .on : .off
            let closure = ActionMenuClosure { [weak self] in self?.writePinned(setting.toggling(id)) }
            row.target = closure
            row.representedObject = closure
            submenu.addItem(row)
        }
        item.submenu = submenu
        return item
    }
}

enum PaneToolbarStrings {
    static var showInTabBar: String { String(localized: "paneToolbar.showInTabBar", defaultValue: "Show in Tab Bar", bundle: .module) }
}
