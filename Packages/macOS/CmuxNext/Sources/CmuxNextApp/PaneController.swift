import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs
import Observation

/// Mirrors one daemon pane into a tab strip and shows the selected tab's
/// content. Tab selection is client-local (`WindowState.selection`); every
/// other change is a daemon command (PaneController+Intents).
final class PaneController {
    let paneKey: String
    let layoutPaneID: LayoutPaneID
    let pane: PaneModel
    /// The machine daemon that owns `pane`.
    let daemon: DaemonService
    let stripModel = TabStripModel()
    let view: PaneContentView
    unowned let services: AppServices
    unowned let state: WindowState
    weak var workspace: WorkspaceContentController?

    private(set) var currentTabKey: String?
    private(set) var isVisible = false
    /// Tabs closed locally while the daemon confirms (Chrome-speed close).
    var pendingClosed: Set<String> = []
    /// A tab this app just created here; selected once the daemon reports it.
    var pendingSelectSurface: SurfaceID?
    /// Same, named by tab resource id (a reopened tab's restored view).
    var pendingSelectTab: String?
    /// A blank browser tab this app just created; its address bar takes
    /// focus once its page exists (CEF pages arrive asynchronously).
    var pendingAddressBarFocus: SurfaceID?
    private var observation: Task<Void, Never>?
    private var buttonsObservation: Task<Void, Never>?

    struct Snapshot: Equatable {
        var items: [StripTabItem]
        var groups: [TabGroupItem]
        var defaultIndex: Int
        var connected: Bool
        var generation: String?
        var surfaces: [UInt64]
    }

    init(pane: PaneModel, daemon: DaemonService, layoutPaneID: LayoutPaneID, services: AppServices, state: WindowState) {
        self.pane = pane
        self.daemon = daemon
        paneKey = pane.id
        self.layoutPaneID = layoutPaneID
        self.services = services
        self.state = state
        view = PaneContentView(stripModel: stripModel)
        stripModel.intentHandler = { [weak self] intent in self?.handle(intent) }
        view.stripView.previewProvider = services.previews
        view.stripView.contextMenuProvider = { [weak self] target in self?.contextMenu(for: target) }
        view.onFocus = { [weak self] in self?.didFocus() }
        view.onWindow = { [weak self] in
            guard let self, self.workspace?.layoutModel.focusedPane == self.layoutPaneID else { return }
            self.focusContent()
        }
        observe()
    }

    func teardown() {
        observation?.cancel()
        buttonsObservation?.cancel()
        services.presentation.cancel(self)
        if let currentTabKey { services.cache.setVisible(currentTabKey, false) }
        currentTabKey = nil
        view.show(nil)
    }

    // MARK: Sync

    private func observe() {
        observation = Task { [weak self] in
            guard let self else { return }
            for await snapshot in Observations({ [weak self] in self?.snapshot() }) {
                guard let snapshot else { return }
                self.apply(snapshot)
            }
        }
        apply(snapshot())
        let buttons = services.tabBarButtons!
        buttonsObservation = Task { [weak self] in
            for await list in Observations({ buttons.buttons }) {
                guard let self else { return }
                if self.stripModel.trailingButtons != list { self.stripModel.trailingButtons = list }
            }
        }
    }

    func snapshot() -> Snapshot {
        let store = daemon.store
        let fallback = Strings.untitledTerminal
        var items = pane.tabs.filter { !pendingClosed.contains($0.id) }.map { tab -> StripTabItem in
            var item = TabItemMapping.item(tab, fallbackTitle: tab.kind == .browser ? Strings.untitledBrowser : fallback)
            item.groupID = tab.tabGroup.map { TabGroupID($0.rawValue) }
            return item
        }
        for local in state.localBrowserTabs[paneKey] ?? [] where !pendingClosed.contains(local.id) {
            let page = services.cache.existingBrowser(local.id)?.tab.state
            let title = page?.title.flatMap { $0.isEmpty ? nil : $0 } ?? page?.url?.host() ?? Strings.untitledBrowser
            items.append(StripTabItem(id: StripTabID(local.id), title: title, subtitle: page?.url?.absoluteString,
                                      icon: .symbol("globe"), isBusy: page?.isLoading ?? false))
        }
        let saved = Set(store.savedTabGroups.compactMap(\.openGroup))
        let groups = pane.tabGroups.map { group in
            TabGroupItem(id: TabGroupID(group.id.rawValue), name: group.name,
                         colorToken: group.color.flatMap(GroupColor.init(rawValue:)) ?? .grey,
                         isCollapsed: group.collapsed, isSaved: saved.contains(group.id))
        }
        let connected = if case .connected = store.connectionState { true } else { false }
        return Snapshot(items: items, groups: groups, defaultIndex: pane.defaultTabIndex, connected: connected,
                        generation: store.generation?.rawValue, surfaces: pane.tabs.map(\.surface.rawValue))
    }

    /// Pushes daemon truth into the strip. `force` resets optimistic strip
    /// state after a rejected command (order, membership, closes).
    func apply(_ snapshot: Snapshot, force: Bool = false) {
        if force { view.stripView.discardPendingReorder() }
        if stripModel.groups != snapshot.groups { stripModel.groups = snapshot.groups }
        if stripModel.tabs != snapshot.items { stripModel.tabs = snapshot.items }
        var focusNew = false
        if let pending = pendingSelectSurface, let tab = pane.tabs.first(where: { $0.surface == pending }) {
            state.selection.select(tab.id, in: paneKey)
            pendingSelectSurface = nil
            focusNew = true
        } else if let pending = pendingSelectTab, let tab = pane.tabs.first(where: { $0.id == pending }) {
            state.selection.select(tab.id, in: paneKey)
            pendingSelectTab = nil
            focusNew = true
        }
        let selected = state.selection.resolve(pane: paneKey, tabs: snapshot.items.map(\.id.rawValue), defaultIndex: snapshot.defaultIndex)
        let selectedID = selected.map { StripTabID($0) }
        if stripModel.selectedID != selectedID { stripModel.selectedID = selectedID }
        if focusNew {
            showSelected()
            focusContent()
        } else {
            // Model-driven: show on the next frame, coalescing transient selections.
            services.presentation.setNeedsShowSelected(self)
        }
    }

    /// Re-pushes daemon truth after a rejection.
    func resyncStrip() {
        apply(snapshot(), force: true)
    }

    // MARK: Content

    func showSelected() {
        let key = stripModel.selectedID?.rawValue
        let content = key.flatMap(content(for:))
        if key != currentTabKey {
            if let currentTabKey { services.cache.setVisible(currentTabKey, false) }
            currentTabKey = key
            if let key { services.cache.setVisible(key, isVisible) }
        }
        view.show(content?.view)
        services.surfaceInvariant.noteChange()
        if let pending = pendingAddressBarFocus, case .browser(let entry) = content, selectedTab?.surface == pending {
            pendingAddressBarFocus = nil
            entry.chrome.perform(.focusAddressBar)
        }
        if isFocusedInWorkspace { workspace?.publishContext() }
    }

    /// This pane is its workspace's focused pane.
    var isFocusedInWorkspace: Bool {
        workspace?.layoutModel.focusedPane == layoutPaneID
    }

    func content(for key: String) -> TabContent? {
        if key.hasPrefix(LocalBrowserTab.prefix) {
            let local = state.localBrowserTabs[paneKey]?.first { $0.id == key }
            return .browser(services.cache.browser(for: key, url: local?.url))
        }
        guard let tab = pane.tabs.first(where: { $0.id == key }) else { return nil }
        switch tab.kind {
        case .pty:
            return .terminal(services.cache.terminal(for: tab, daemon: daemon))
        case .browser where tab.isFrontendOwned:
            return services.cache.browser(for: tab).map(TabContent.browser)
        default:
            return nil
        }
    }

    var currentContent: TabContent? { currentTabKey.flatMap(content(for:)) }

    /// `key`'s live content, if its surface or page exists.
    func existingContent(for key: String) -> TabContent? {
        if let entry = services.cache.existingTerminal(key) { return .terminal(entry) }
        return services.cache.existingBrowser(key).map(TabContent.browser)
    }

    /// True when showing the selection needs no new surface or page.
    var selectedContentIsAlive: Bool {
        guard let key = stripModel.selectedID?.rawValue else { return true }
        return key == currentTabKey || services.cache.hasContent(for: key)
    }

    /// The layout reported this pane on or off screen.
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if let currentTabKey { services.cache.setVisible(currentTabKey, visible) }
    }

    /// Makes the selected content first responder.
    func focusContent() {
        guard let target = currentContent?.focusTarget, let window = view.window else { return }
        if window.firstResponder !== target { window.makeFirstResponder(target) }
    }

    var containsFirstResponder: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    private func didFocus() {
        workspace?.paneDidFocus(self)
    }

    // MARK: Lookup

    func tab(_ id: StripTabID) -> TabModel? { pane.tabs.first { $0.id == id.rawValue } }

    var selectedTab: TabModel? { stripModel.selectedID.flatMap(tab) }

    var orderedIDs: [StripTabID] { stripModel.orderedTabs.map(\.id) }
}
