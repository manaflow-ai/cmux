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
/// Lawrence 2026-10-12) and a zoomed pane's Exit Zoom. The bar has no "…" pane actions menu (user 2026-11-23,
/// https://github.com/manaflow-ai/cmux/issues/53356: "this menu and the three dots ant the end, no more"). What it
/// listed stays reachable: creation on the strip's + and its keys, the splits, zoom and Search Tabs on their keys and
/// the command palette, Switch to Chat and the content's own rows (the docked Home's Chief Actions) on the tab's
/// right-click, and pins through the palette's Pin or Unpin Tab Bar Button… (``togglePin``). A chat's pane draws its own
/// tools (acpmux header/ChatHeaderTools.tsx), whose ⋮ offers Switch to Terminal.
@MainActor
final class PaneToolbar: PaneControlsRefreshing {
    /// What the selected tab is, for its own actions; nil is a chat: no pins.
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
    /// Subagents), first in the selected tab's right-click.
    private let contentMenu: () -> [NSMenuItem]
    private(set) var target: String?
    private(set) var kind: Kind?
    private(set) var zoomed = false
    private(set) var pinned: [String] = []
    private var observation: Task<Void, Never>?
    private var refreshCurrent: (() -> Void)?

    init(registry: @escaping () -> ActionRegistry?, paneTarget: ActionTargetRef? = nil,
         contentMenu: @escaping () -> [NSMenuItem] = { [] },
         machineID: @escaping () -> String? = { nil }, view: PaneToolbarView = PaneToolbarView()) {
        (self.view, self.registry) = (view, registry)
        self.machineID = machineID
        self.paneTarget = paneTarget
        self.contentMenu = contentMenu
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
                  machineID: { [weak pane] in pane?.daemon.machineID }, view: view ?? PaneToolbarView())
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

    static let zoom: ActionID = "toggleSplitZoom"

    /// Shows the `pinned` actions tab `target` of `kind` can run (nil kind: none), and the Exit Zoom button while the pane
    /// is zoomed. `paneKinds`: the kinds of every tab in the pane, whichever is selected.
    func update(target: String?, kind: Kind?, zoomed: Bool = false, pinned: [String] = [], paneKinds: Set<Kind> = [], nativeItems: [PaneTabRowTool] = [], nativeEnabled: Bool = ChromeTunables.nativeRowTools.value) {
        self.target = target
        self.kind = kind
        self.zoomed = zoomed
        self.pinned = pinned
        // The room the bar keeps: the most pins any tab of the pane shows, so selecting a tab with fewer pins (a chat,
        // a window's own page) moves no tab, plus Exit Zoom's slot while the pane is zoomed (a pinned zoom gives way to
        // it, so it is not counted twice). With no pins the bar keeps no room: the strip runs to the trailing gap.
        let kinds = kind.map { paneKinds.union([$0]) } ?? paneKinds
        let reservedPins = kinds.map { kind in
            pinned.count(where: { (!zoomed || $0 != Self.zoom.rawValue) && Self.actions(kind).contains(ActionID(rawValue: $0)) })
        }.max() ?? 0
        let buttons = shownButtons()
        // The new-terminal and new-browser buttons are not shown: the + offers them (Lawrence 2026-10-27: too many buttons).
        let nativeTools = nativeEnabled ? nativeItems : []
        view.show(buttons.compactMap(item), zoomed: zoomed, reserving: max(reservedPins, buttons.count) + (zoomed ? 1 : 0),
                  nativeItems: nativeTools)
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

    /// The shown content's own rows (the docked Home's Chief Actions and Subagents), fresh each call.
    func contentRows() -> [NSMenuItem] { contentMenu() }
}

/// Pin or Unpin Tab Bar Button… (`tabs.toolbar.togglePin`, `button`: an action id `tabs.toolbarButtons` takes): the
/// palette's one way to pin or unpin a tab bar button. It lists the pinnable actions, the pinned ones marked
/// (`tabBarButtons`).
extension PaneToolbar {
    static let togglePin: ActionID = "tabs.toolbar.togglePin"

    static func bindTogglePin(into registry: ActionRegistry, settings: @escaping @MainActor () -> SettingsController?) {
        registry.bindEffect(togglePin, isEnabled: { settings() != nil }, effect: { invocation in
            guard let settings = settings(), let id = invocation["button"]?.stringValue,
                  PaneToolbarButtonsSetting.values.contains(id) else { return .done }
            write(pinnedSetting(in: settings).toggling(id), in: settings)
            return .done
        })
        let other = registry.argumentSuggestions
        registry.argumentSuggestions = { [weak registry] source in
            guard source == ActionSuggestions.tabBarButtons else { return other?(source) ?? [] }
            let pinned = settings().map { pinnedSetting(in: $0).pinned } ?? []
            return PaneToolbarButtonsSetting.values.compactMap { id in
                guard let title = registry?.descriptor(for: ActionID(rawValue: id))?.title else { return nil }
                return ActionEnumCase(value: id, title: title, symbol: pinned.contains(id) ? "pin.fill" : "pin")
            }
        }
    }

    /// The pinned list last asked for, until its write lands. A second quick toggle starts from it: read from the
    /// file, two toggles both saw the old list and the later write dropped the earlier pin.
    private static var pendingPinned: PaneToolbarButtonsSetting?
    /// The write in flight; the next one waits for it, so the file takes the toggles in the order they were asked.
    private static var lastWrite: Task<Void, Never>?

    /// The pinned list a toggle starts from: the one still being written, else the file's.
    static func pinnedSetting(in settings: SettingsController) -> PaneToolbarButtonsSetting {
        pendingPinned ?? PaneToolbarButtonsSetting.current(settings)
    }

    /// Writes the pinned list (`tabs.toolbarButtons`); every pane follows the file. Writes go one at a time, in order.
    static func write(_ next: PaneToolbarButtonsSetting, in settings: SettingsController) {
        pendingPinned = next
        let previous = lastWrite
        let writer = SettingWriter.currentRun() // the menu item's or palette row's gesture is the user's
        // task-owner: one write, after the one before it (lastWrite); ends when the file has it
        let task = Task {
            await previous?.value
            do { try await settings.setSetting(at: PaneToolbarButtonsSetting.configPath, to: next.configValue, by: writer) } catch {
                Logger(subsystem: "com.cmuxterm.app.next", category: "pane-toolbar").error("tabs.toolbarButtons write failed: \(String(describing: error), privacy: .public)")
            }
            if pendingPinned == next { pendingPinned = nil }
        }
        lastWrite = task
    }
}
