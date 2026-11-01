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

/// A pane's "…" at its tab bar's trailing end (Leo 2026-10-12; was cx-kk7lm's row of buttons), after
/// the actions pinned as buttons (`tabs.toolbarButtons`, none by default; Lawrence 2026-10-12): they
/// show only while the pointer is over the tab bar, like its "+". The menu is the strip plus's (a terminal,
/// a browser, an agent chat, … in this pane), then the splits and zoom not pinned, Search Tabs,
/// then Show in Tab Bar, which pins or unpins one. Content tools remain pinnable and searchable. A chat's
/// pane has none: its header has its own (acpmux header/ChatHeaderTools.tsx).
@MainActor
final class PaneToolbar {
    /// What the selected tab is, for its own actions; nil is a chat: no "…".
    enum Kind: Hashable, Sendable {
        case newTab, terminal, browser, other
    }

    /// What the bar follows: the selected tab, its kind, whether the pane is zoomed and the pins.
    struct State: Equatable, Sendable {
        var target: String?
        var kind: Kind?
        var zoomed = false
        var pinned: [String] = []
        /// What every tab of the pane that offers "…" is: the bar keeps their room whichever is
        /// selected, so a selection never changes the strip's width (Lawrence 2026-10-19).
        var paneKinds: Set<Kind> = []
        /// The strip selects a tab the store no longer lists (a provisional tab the store's tab
        /// just replaced): the selection follows on the strip's next apply, so the bar keeps what
        /// it shows. Hiding "…" for that frame gave its width to the strip, which laid out every
        /// tab again at once (10 tabs, cx-codh2).
        var behind = false
        var nativeOwnerID: ObjectIdentifier?
        var nativeItems: [PaneTabRowTool] = []
        var nativeEnabled = false
    }

    let view = PaneToolbarView()
    private let registry: () -> ActionRegistry?
    private let paneTarget: ActionTargetRef?
    private let machineID: () -> String?
    static let creationActions: [ActionID] = ["newSurface", "openBrowser"]
    /// The strip plus's menu for this pane (what opens in it).
    private let newTabMenu: () -> NSMenu?
    /// The shown content's own rows, first in the menu (``PaneMoreMenuContributing``: the docked
    /// Home's Chief Actions), so the pane keeps one ⋮.
    private let contentMenu: () -> [NSMenuItem]
    private(set) var target: String?
    private(set) var kind: Kind?
    private(set) var zoomed = false
    private(set) var pinned: [String] = []
    /// Writes the pinned list (`tabs.toolbarButtons`); every pane follows the file.
    var writePinned: (PaneToolbarButtonsSetting) -> Void = { _ in }
    private var observation: Task<Void, Never>?
    private var refreshCurrent: (() -> Void)?

    init(registry: @escaping () -> ActionRegistry?, newTabMenu: @escaping () -> NSMenu?, paneTarget: ActionTargetRef? = nil,
         contentMenu: @escaping () -> [NSMenuItem] = { [] }, machineID: @escaping () -> String? = { nil }) {
        self.registry = registry
        self.machineID = machineID
        self.paneTarget = paneTarget
        self.newTabMenu = newTabMenu
        self.contentMenu = contentMenu
        view.moreMenu = { [weak self] in self?.moreMenu() }
        view.onPerform = { [weak self] id in self?.perform(ActionID(rawValue: id)) }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        observation?.cancel()
    }

    /// The pane's "…": follows its selected tab and the pane's zoom.
    convenience init(pane: PaneController) {
        let services = pane.services
        self.init(registry: { [weak services] in services?.registry },
                  newTabMenu: { [weak pane] in
                      // The plus's rows, without its Chromium warmup: "…" is opened for a split as often.
                      // Its rows join the "…" menu, so no Customize Menu… of the New Tab menu.
                      pane.map { $0.services.registry.makeContextMenu(for: .newTab, target: ActionTargetRef(kind: .pane, id: $0.paneKey), customize: false) }
                  },
                  paneTarget: ActionTargetRef(kind: .pane, id: pane.paneKey),
                  contentMenu: { [weak pane] in (pane?.view.content as? PaneMoreMenuContributing)?.paneMoreMenuItems() ?? [] }, machineID: { [weak pane] in pane?.daemon.machineID })
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
            guard let self, let pane else { return }
            self.apply(Self.state(pane), owner: pane.view.nativeToolOwner)
        }
        // task-owner: lives as long as the pane's view; event-driven (Observation)
        observation = Task { [weak self, weak pane] in
            for await state in ObservationStream({ [weak pane] in pane.map(Self.state) }) {
                guard let self, let state else { return }
                guard let pane else { return }
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
        update(target: state.behind ? target : state.target, kind: state.behind ? kind : state.kind,
               zoomed: state.zoomed, pinned: state.pinned, paneKinds: state.paneKinds, nativeItems: state.nativeItems, nativeEnabled: state.nativeEnabled)
    }

    private static func state(_ pane: PaneController) -> State {
        let displayedModel = pane.view.nativeToolOwner.model
        let pinned = pane.services.settings.map { PaneToolbarButtonsSetting.current($0).pinned } ?? []
        let resolver = TabTitleResolver(services: pane.services)
        let paneKinds = Set(pane.pane.tabs.compactMap { kind($0, isNewTabPage: resolver.isNewTabPage($0)) })
        // The pane's own workspace, not a store scan: this runs for every pane.
        let zoomed = pane.workspace?.workspace.screens.contains { $0.zoomedPane == pane.pane.handle } ?? false
        guard let key = pane.stripModel.selectedID?.rawValue else { return State(zoomed: zoomed, pinned: pinned, paneKinds: paneKinds, nativeOwnerID: displayedModel.map(ObjectIdentifier.init), nativeItems: displayedModel?.tabRowTools ?? [], nativeEnabled: displayedModel?.tabRow.nativeToolsEnabled == true) }
        guard let tab = pane.pane.tabs.first(where: { $0.id == key }) else {
            // A window's own page or browser tab is never in the store: no "…", not a stale bar.
            let local = key.hasPrefix(LocalPageTab.prefix) || key.hasPrefix(LocalBrowserTab.prefix)
            return State(zoomed: zoomed, pinned: pinned, paneKinds: paneKinds, behind: !local, nativeOwnerID: displayedModel.map(ObjectIdentifier.init), nativeItems: displayedModel?.tabRowTools ?? [], nativeEnabled: displayedModel?.tabRow.nativeToolsEnabled == true)
        }
        return State(target: key, kind: kind(tab, isNewTabPage: resolver.isNewTabPage(tab)), zoomed: zoomed, pinned: pinned, paneKinds: paneKinds, nativeOwnerID: displayedModel.map(ObjectIdentifier.init), nativeItems: displayedModel?.tabRowTools ?? [], nativeEnabled: displayedModel?.tabRow.nativeToolsEnabled == true)
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

    /// Shows the `pinned` actions tab `target` of `kind` can run and "…" (nil kind: none); lit, with a
    /// pinned zoom button, while the pane is zoomed.
    /// `paneKinds`: the kinds of every tab in the pane that offers "…", whichever is selected.
    func update(target: String?, kind: Kind?, zoomed: Bool = false, pinned: [String] = [], paneKinds: Set<Kind> = [], nativeItems: [PaneTabRowTool] = [], nativeEnabled: Bool = ChromeTunables.nativeRowTools.value) {
        self.target = target
        self.kind = kind
        self.zoomed = zoomed
        self.pinned = pinned
        let shown = target != nil && kind != nil
        // The room the bar keeps: "…" and the most pins any tab of the pane shows, so selecting a tab
        // without "…" (a chat, a window's own page) or fewer pins moves no tab. Search Tabs has no button
        // (Lawrence 2026-10-20: "i dont like the down arrow"); it is a row of "…"'s menu.
        let kinds = kind.map { paneKinds.union([$0]) } ?? paneKinds
        let reservedPins = kinds.map { kind in pinned.count(where: { Self.actions(kind).contains(ActionID(rawValue: $0)) }) }.max() ?? 0
        // The zoom indicator is on the selected tab (`TabStripModel.zoomsSelected`), not a button here:
        // a zoom keeps this room, so the strip's width and every tab stay put.
        let buttons = shownButtons()
        // The new-terminal and new-browser buttons are not shown: the + and the "…" menu offer them (Lawrence 2026-10-27: too many buttons).
        // A native page list needs an overflow route when a narrow pane cannot fit every real
        // button. It also keeps chat panes discoverable, which otherwise have no pane "…".
        let nativeTools = nativeEnabled ? nativeItems : []
        view.show(buttons.compactMap(item), more: shown || !nativeTools.isEmpty, lit: zoomed && shown,
                  reserving: kinds.isEmpty ? 0 : max(reservedPins, buttons.count) + 1,
                  nativeItems: nativeTools)
    }

    /// The pinned actions the tab can run, in the user's order, as buttons before "…".
    func shownPins() -> [ActionID] { pinned.map(ActionID.init(rawValue:)).filter(tabActions().contains) }

    /// The buttons before "…": the pins; a pinned zoom button is lit while the pane is zoomed. An
    /// unpinned one never shows: the selected tab carries the zoom indicator (#25624).
    func shownButtons() -> [ActionID] { shownPins() }

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
            _ = registry()?.perform(id, invocation: ActionInvocation(target: paneTarget, origin: .user))
            return
        }
        guard let invocation = tabInvocation() else { return }
        _ = registry()?.perform(id, invocation: invocation)
    }

    private func tabInvocation() -> ActionInvocation? { target.map { ActionInvocation(target: ActionTargetRef(kind: .tab, id: $0), origin: .user).onMachine(machineID()) } }

    /// The tab's actions "…" offers: those it can run.
    func tabActions() -> [ActionID] {
        guard let registry = registry(), let invocation = tabInvocation(), let kind else { return [] }
        return Self.actions(kind).filter { ActionTargetReasons.canPerform($0, invocation: invocation, in: registry) }
    }

    /// "…": the content's own rows (the Chief's), what opens in the pane, the actions without a button
    /// with their keys, Search Tabs, then Show in Tab Bar.
    private func moreMenu() -> NSMenu? {
        guard let registry = registry(), let target else { return nil }
        let menu = newTabMenu() ?? NSMenu()
        // The plus keeps the full creation menu; overflow keeps the common tab kinds.
        for item in menu.items where ActionRegistry.menuRun(of: item).map({ Self.overflowNewTabTrimmedActions.contains($0.id) }) == true {
            menu.removeItem(item)
        }
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) }
            previousWasSeparator = item.isSeparatorItem
        }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        let own = contentMenu()
        if !own.isEmpty, !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        for (index, item) in own.enumerated() { menu.insertItem(item, at: index) }
        view.layoutSubtreeIfNeeded()
        let buttons = zip(view.items, view.buttons).compactMap { item, button in
            button.isHidden ? nil : ActionID(rawValue: item.id)
        }
        let tabOwn = registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: target),
                                              entries: tabActions().filter {
                                                  !buttons.contains($0) && (!Self.overflowTabTrimmedActions.contains($0) || pinned.contains($0.rawValue))
                                              }.map { .action($0) }, machineID: machineID())
        if !menu.items.isEmpty, !tabOwn.items.isEmpty { menu.addItem(.separator()) }
        for item in tabOwn.items {
            tabOwn.removeItem(item)
            menu.addItem(item)
        }
        if kind != nil {
            // Search Tabs (was the bar's chevron) runs with no tab target: a tab target only reveals that tab.
            let search = registry.makeContextMenu(for: .tab, entries: [.action(Self.search)])
            if !search.items.isEmpty { menu.addItem(.separator()) }
            for item in search.items {
                search.removeItem(item)
                menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(showInTabBarItem(registry: registry))
        }
        let native = view.nativeOverflowItems()
        if !native.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            native.forEach(menu.addItem)
        }
        // Every row in the theme's highlight, like the sidebar's ⋮ menus and the strip's plus.
        return menu.themeRows(in: view.themeScope.fullStrength)
    }

    /// Show in Tab Bar: the selected kind's controls, plus existing pins so they can be unpinned.
    private func showInTabBarItem(registry: ActionRegistry) -> NSMenuItem {
        let item = NSMenuItem(title: PaneToolbarStrings.showInTabBar, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: PaneToolbarStrings.showInTabBar)
        let setting = PaneToolbarButtonsSetting(pinned: pinned)
        let available = Set(kind.map(Self.actions) ?? [])
        for id in PaneToolbarButtonsSetting.buttonIDs where available.contains(ActionID(rawValue: id)) || pinned.contains(id) {
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
