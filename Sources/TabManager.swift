import AppKit
import SwiftUI
import Foundation

class Tab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var currentDirectory: String
    @Published var splitTree: SplitTree<TerminalSurface>
    @Published var focusedSurfaceId: UUID? {
        didSet {
            guard let focusedSurfaceId else { return }
            AppDelegate.shared?.tabManager?.rememberFocusedSurface(tabId: id, surfaceId: focusedSurfaceId)
        }
    }
    @Published var surfaceDirectories: [UUID: String] = [:]
    var splitViewSize: CGSize = .zero

    init(title: String = "Terminal", workingDirectory: String? = nil) {
        self.id = UUID()
        self.title = title
        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWorkingDirectory = !trimmedWorkingDirectory.isEmpty
        self.currentDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path
        let surface = TerminalSurface(
            tabId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: nil,
            workingDirectory: hasWorkingDirectory ? trimmedWorkingDirectory : nil
        )
        self.splitTree = SplitTree(view: surface)
        self.focusedSurfaceId = surface.id
    }

    var focusedSurface: TerminalSurface? {
        guard let focusedSurfaceId else { return nil }
        return surface(for: focusedSurfaceId)
    }

    func surface(for id: UUID) -> TerminalSurface? {
        guard let node = splitTree.root?.find(id: id) else { return nil }
        if case .leaf(let view) = node {
            return view
        }
        return nil
    }

    func focusSurface(_ id: UUID) {
        let wasFocused = focusedSurfaceId == id
        focusedSurfaceId = id
        let isSelectedTab = AppDelegate.shared?.tabManager?.selectedTabId == self.id
        if isSelectedTab {
            focusedSurface?.applyWindowBackgroundIfActive()
        }
        let isAppActive = AppFocusState.isAppActive()
        guard isSelectedTab && isAppActive else { return }
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
        if notificationStore.hasUnreadNotification(forTabId: self.id, surfaceId: id) {
            triggerNotificationFocusFlash(surfaceId: id, requiresSplit: false, shouldFocus: false)
            notificationStore.markRead(forTabId: self.id, surfaceId: id)
            return
        }
        if !wasFocused {
            notificationStore.markRead(forTabId: self.id, surfaceId: id)
        }
    }

    func updateSurfaceDirectory(surfaceId: UUID, directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if surfaceDirectories[surfaceId] != trimmed {
            surfaceDirectories[surfaceId] = trimmed
        }
        currentDirectory = trimmed
    }

    func triggerNotificationFocusFlash(
        surfaceId: UUID,
        requiresSplit: Bool = false,
        shouldFocus: Bool = true
    ) {
        triggerPanelFlash(surfaceId: surfaceId, requiresSplit: requiresSplit, shouldFocus: shouldFocus)
    }

    func triggerDebugFlash(surfaceId: UUID) {
        triggerPanelFlash(surfaceId: surfaceId, requiresSplit: false, shouldFocus: true)
    }

    private func triggerPanelFlash(surfaceId: UUID, requiresSplit: Bool, shouldFocus: Bool) {
        guard let surface = surface(for: surfaceId) else { return }
        if shouldFocus {
            if focusedSurfaceId != surfaceId {
                focusSurface(surfaceId)
            }
            surface.hostedView.ensureFocus(for: self.id, surfaceId: surfaceId)
        }
        if requiresSplit && !splitTree.isSplit {
            return
        }
        triggerFlashWhenReady(surface: surface)
    }

    private func triggerFlashWhenReady(surface: TerminalSurface, attempts: Int = 0) {
        let maxAttempts = 6
        let view = surface.hostedView
        if view.window != nil {
            view.layoutSubtreeIfNeeded()
        }
        let hasBounds = view.bounds.width > 0 && view.bounds.height > 0
        if view.window != nil && hasBounds {
            view.triggerFlash()
            return
        }
        guard attempts < maxAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.triggerFlashWhenReady(surface: surface, attempts: attempts + 1)
        }
    }

    func updateSplitViewSize(_ size: CGSize) {
        guard splitViewSize != size else { return }
        splitViewSize = size
    }

    func updateSplitRatio(node: SplitTree<TerminalSurface>.Node, ratio: Double) {
        do {
            splitTree = try splitTree.replacing(node: node, with: node.resizing(to: ratio))
        } catch {
            return
        }
    }

    func equalizeSplits() {
        splitTree = splitTree.equalized()
    }

    func newSplit(from surfaceId: UUID, direction: SplitTree<TerminalSurface>.NewDirection) -> TerminalSurface? {
        guard let targetSurface = surface(for: surfaceId) else { return nil }
        let inheritedConfig: ghostty_surface_config_s? = if let existing = targetSurface.surface {
            ghostty_surface_inherited_config(existing, GHOSTTY_SURFACE_CONTEXT_SPLIT)
        } else {
            nil
        }

        let newSurface = TerminalSurface(
            tabId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig
        )

        do {
            splitTree = try splitTree.inserting(view: newSurface, at: targetSurface, direction: direction)
            focusedSurfaceId = newSurface.id
            return newSurface
        } catch {
            return nil
        }
    }

    func moveFocus(from surfaceId: UUID, direction: SplitTree<TerminalSurface>.FocusDirection) -> Bool {
        guard let root = splitTree.root,
              let targetNode = root.find(id: surfaceId),
              let nextSurface = splitTree.focusTarget(for: direction, from: targetNode) else {
            return false
        }

        focusedSurfaceId = nextSurface.id
        return true
    }

    func resizeSplit(from surfaceId: UUID, direction: SplitTree<TerminalSurface>.Spatial.Direction, amount: UInt16) -> Bool {
        guard let root = splitTree.root,
              let targetNode = root.find(id: surfaceId),
              splitViewSize.width > 0,
              splitViewSize.height > 0 else {
            return false
        }

        do {
            splitTree = try splitTree.resizing(
                node: targetNode,
                by: amount,
                in: direction,
                with: CGRect(origin: .zero, size: splitViewSize)
            )
            return true
        } catch {
            return false
        }
    }

    func toggleZoom(on surfaceId: UUID) -> Bool {
        guard let root = splitTree.root,
              let targetNode = root.find(id: surfaceId) else {
            return false
        }

        guard splitTree.isSplit else { return false }

        if splitTree.zoomed == targetNode {
            splitTree = SplitTree(root: splitTree.root, zoomed: nil)
        } else {
            splitTree = SplitTree(root: splitTree.root, zoomed: targetNode)
        }
        return true
    }

    private func findNextFocusTargetAfterClosing(
        node: SplitTree<TerminalSurface>.Node
    ) -> TerminalSurface? {
        guard let root = splitTree.root else { return nil }

        if root.leftmostLeaf() === node.leftmostLeaf() {
            return splitTree.focusTarget(for: .next, from: node)
        }

        return splitTree.focusTarget(for: .previous, from: node)
    }

    func closeSurface(_ surfaceId: UUID) -> Bool {
        guard let root = splitTree.root,
              let targetNode = root.find(id: surfaceId) else {
            return false
        }

        let oldFocusedSurface = focusedSurface
        let shouldMoveFocus = if let focusedSurfaceId {
            targetNode.find(id: focusedSurfaceId) != nil
        } else {
            false
        }
        let nextFocus: TerminalSurface? = shouldMoveFocus
            ? findNextFocusTargetAfterClosing(node: targetNode)
            : nil

        splitTree = splitTree.removing(targetNode)

        if splitTree.isEmpty {
            focusedSurfaceId = nil
            return true
        }

        if shouldMoveFocus {
            focusedSurfaceId = nextFocus?.id
        }

        if focusedSurfaceId == nil {
            focusedSurfaceId = splitTree.root?.leftmostLeaf().id
        }

        if !splitTree.isSplit {
            splitTree = SplitTree(root: splitTree.root, zoomed: nil)
        }

        if shouldMoveFocus, let newFocusedSurface = focusedSurface {
            DispatchQueue.main.async {
                newFocusedSurface.hostedView.moveFocus(from: oldFocusedSurface?.hostedView)
            }
        }

        return true
    }
}

class TabManager: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedTabId: UUID? {
        didSet {
            guard selectedTabId != oldValue else { return }
            let previousTabId = oldValue
            if let previousTabId,
               let previousSurfaceId = focusedSurfaceId(for: previousTabId) {
                lastFocusedSurfaceByTab[previousTabId] = previousSurfaceId
            }
            DispatchQueue.main.async { [weak self] in
                self?.focusSelectedTabSurface(previousTabId: previousTabId)
                self?.updateWindowTitleForSelectedTab()
                if let selectedTabId = self?.selectedTabId {
                    self?.markFocusedPanelReadIfActive(tabId: selectedTabId)
                }
            }
        }
    }
    private var observers: [NSObjectProtocol] = []
    private var suppressFocusFlash = false
    private var lastFocusedSurfaceByTab: [UUID: UUID] = [:]

    init() {
        addTab()
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else { return }
            self.updateTabTitle(tabId: tabId, title: title)
        })
    }

    var selectedTab: Tab? {
        guard let selectedTabId else { return nil }
        return tabs.first(where: { $0.id == selectedTabId })
    }

    var selectedSurface: TerminalSurface? {
        selectedTab?.focusedSurface
    }

    var isFindVisible: Bool {
        selectedSurface?.searchState != nil
    }

    var canUseSelectionForFind: Bool {
        selectedSurface?.hasSelection() == true
    }

    func startSearch() {
        guard let surface = selectedSurface else { return }
        if surface.searchState == nil {
            surface.searchState = TerminalSurface.SearchState()
        }
        NSLog("Find: startSearch tab=%@ surface=%@", surface.tabId.uuidString, surface.id.uuidString)
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: surface)
        _ = surface.performBindingAction("start_search")
    }

    func searchSelection() {
        guard let surface = selectedSurface else { return }
        if surface.searchState == nil {
            surface.searchState = TerminalSurface.SearchState()
        }
        NSLog("Find: searchSelection tab=%@ surface=%@", surface.tabId.uuidString, surface.id.uuidString)
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: surface)
        _ = surface.performBindingAction("search_selection")
    }

    func findNext() {
        _ = selectedSurface?.performBindingAction("search:next")
    }

    func findPrevious() {
        _ = selectedSurface?.performBindingAction("search:previous")
    }

    func hideFind() {
        selectedSurface?.searchState = nil
    }

    func tickRender() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }
        for surface in tab.splitTree.map({ $0 }) {
            surface.renderIfVisible()
        }
    }

    @discardableResult
    func addTab() -> Tab {
        let workingDirectory = preferredWorkingDirectoryForNewTab()
        let newTab = Tab(title: "Terminal \(tabs.count + 1)", workingDirectory: workingDirectory)
        let insertIndex = newTabInsertIndex()
        if insertIndex >= 0 && insertIndex <= tabs.count {
            tabs.insert(newTab, at: insertIndex)
        } else {
            tabs.append(newTab)
        }
        selectedTabId = newTab.id
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: newTab.id]
        )
        return newTab
    }

    private func newTabInsertIndex() -> Int {
        guard let selectedTabId,
              let index = tabs.firstIndex(where: { $0.id == selectedTabId }) else {
            return tabs.count
        }
        return min(index + 1, tabs.count)
    }

    private func preferredWorkingDirectoryForNewTab() -> String? {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else {
            return nil
        }
        let focusedDirectory = tab.focusedSurfaceId
            .flatMap { tab.surfaceDirectories[$0] }
        let candidate = focusedDirectory ?? tab.currentDirectory
        let normalized = normalizeDirectory(candidate)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : normalized
    }

    func moveTabToTop(_ tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        guard index != 0 else { return }
        let tab = tabs.remove(at: index)
        tabs.insert(tab, at: 0)
    }

    func moveTabsToTop(_ tabIds: Set<UUID>) {
        guard !tabIds.isEmpty else { return }
        let selectedTabs = tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let remainingTabs = tabs.filter { !tabIds.contains($0.id) }
        tabs = selectedTabs + remainingTabs
    }

    func updateSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let normalized = normalizeDirectory(directory)
        tab.updateSurfaceDirectory(surfaceId: surfaceId, directory: normalized)
    }

    private func normalizeDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            if !url.path.isEmpty {
                return url.path
            }
        }
        return trimmed
    }

    func closeTab(_ tab: Tab) {
        guard tabs.count > 1 else { return }

        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id)

        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: index)

            if selectedTabId == tab.id {
                if index > 0 {
                    selectedTabId = tabs[index - 1].id
                } else {
                    selectedTabId = tabs.first?.id
                }
            }
        }
    }

    func closeCurrentTab() {
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }) else { return }
        closeTab(tab)
    }

    func closeCurrentPanelWithConfirmation() {
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }),
              let focusedSurfaceId = tab.focusedSurfaceId else { return }
        closePanelWithConfirmation(tab: tab, surfaceId: focusedSurfaceId)
    }

    func closeCurrentTabWithConfirmation() {
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }) else { return }
        closeTabIfRunningProcess(tab)
    }

    func selectTab(_ tab: Tab) {
        selectedTabId = tab.id
    }

    private func confirmClose(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func closeTabIfRunningProcess(_ tab: Tab) {
        guard tabs.count > 1 else { return }
        if tabNeedsConfirmClose(tab),
           !confirmClose(
               title: "Close tab?",
               message: "This will close the current tab and all of its panels."
           ) {
            return
        }
        closeTab(tab)
    }

    private func closePanelWithConfirmation(tab: Tab, surfaceId: UUID) {
        guard tab.splitTree.isSplit else {
            closeTabIfRunningProcess(tab)
            return
        }

        let surface = tab.surface(for: surfaceId)
        if surface?.needsConfirmClose() == true {
            guard confirmClose(
                title: "Close panel?",
                message: "This will close the current split panel in this tab."
            ) else { return }
        }

        _ = closeSurface(tabId: tab.id, surfaceId: surfaceId)
    }

    func closePanelWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        closePanelWithConfirmation(tab: tab, surfaceId: surfaceId)
    }

    private func tabNeedsConfirmClose(_ tab: Tab) -> Bool {
        guard let root = tab.splitTree.root else { return false }
        return root.leaves().contains { $0.needsConfirmClose() }
    }

    func titleForTab(_ tabId: UUID) -> String? {
        tabs.first(where: { $0.id == tabId })?.title
    }

    func focusedSurfaceId(for tabId: UUID) -> UUID? {
        tabs.first(where: { $0.id == tabId })?.focusedSurfaceId
    }

    func rememberFocusedSurface(tabId: UUID, surfaceId: UUID) {
        lastFocusedSurfaceByTab[tabId] = surfaceId
    }

    func applyWindowBackgroundForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let surface = tab.focusedSurface else { return }
        surface.applyWindowBackgroundIfActive()
    }

    private func focusSelectedTabSurface(previousTabId: UUID?) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }
        if let restoredSurfaceId = lastFocusedSurfaceByTab[selectedTabId],
           tab.surface(for: restoredSurfaceId) != nil,
           tab.focusedSurfaceId != restoredSurfaceId {
            tab.focusedSurfaceId = restoredSurfaceId
        }
        guard let surface = tab.focusedSurface else { return }
        let previousSurface = previousTabId.flatMap { id in
            tabs.first(where: { $0.id == id })?.focusedSurface
        }
        surface.hostedView.moveFocus(from: previousSurface?.hostedView)
        surface.hostedView.ensureFocus(for: selectedTabId, surfaceId: surface.id)
    }

    private func markFocusedPanelReadIfActive(tabId: UUID) {
        let shouldSuppressFlash = suppressFocusFlash
        suppressFocusFlash = false
        guard !shouldSuppressFlash else { return }
        guard AppFocusState.isAppActive() else { return }
        guard let surfaceId = focusedSurfaceId(for: tabId) else { return }
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
        guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surfaceId) else { return }
        if let tab = tabs.first(where: { $0.id == tabId }) {
            tab.triggerNotificationFocusFlash(surfaceId: surfaceId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forTabId: tabId, surfaceId: surfaceId)
    }

    private func updateTabTitle(tabId: UUID, title: String) {
        guard !title.isEmpty else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        if tabs[index].title != title {
            tabs[index].title = title
            if selectedTabId == tabId {
                updateWindowTitle(for: tabs[index])
            }
        }
    }

    private func updateWindowTitleForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else {
            updateWindowTitle(for: nil)
            return
        }
        updateWindowTitle(for: tab)
    }

    private func updateWindowTitle(for tab: Tab?) {
        let title = windowTitle(for: tab)
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
        targetWindow?.title = title
    }

    private func windowTitle(for tab: Tab?) -> String {
        guard let tab else { return "cmuxterm" }
        let trimmedTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let trimmedDirectory = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDirectory.isEmpty ? "cmuxterm" : trimmedDirectory
    }

    func focusTab(_ tabId: UUID, surfaceId: UUID? = nil, suppressFlash: Bool = false) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        selectedTabId = tabId
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: tabId]
        )

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.unhide(nil)
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }

        if let surfaceId {
            if !suppressFlash {
                focusSurface(tabId: tabId, surfaceId: surfaceId)
            } else if let tab = tabs.first(where: { $0.id == tabId }) {
                tab.focusedSurfaceId = surfaceId
            }
        }
    }

    func focusTabFromNotification(_ tabId: UUID, surfaceId: UUID? = nil) {
        let wasSelected = selectedTabId == tabId
        let desiredSurfaceId = surfaceId ?? tabs.first(where: { $0.id == tabId })?.focusedSurfaceId
#if DEBUG
        if let desiredSurfaceId {
            AppDelegate.shared?.armJumpUnreadFocusRecord(tabId: tabId, surfaceId: desiredSurfaceId)
        }
#endif
        suppressFocusFlash = true
        focusTab(tabId, surfaceId: desiredSurfaceId, suppressFlash: true)
        if wasSelected {
            suppressFocusFlash = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  let tab = self.tabs.first(where: { $0.id == tabId }) else { return }
            let targetSurfaceId = desiredSurfaceId ?? tab.focusedSurfaceId
            guard let targetSurfaceId,
                  tab.surface(for: targetSurfaceId) != nil else { return }
            guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
            guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: targetSurfaceId) else { return }
            tab.triggerNotificationFocusFlash(surfaceId: targetSurfaceId, requiresSplit: false, shouldFocus: true)
            notificationStore.markRead(forTabId: tabId, surfaceId: targetSurfaceId)
        }
    }

    func focusSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.focusSurface(surfaceId)
    }

    func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectedTabId = tabs[nextIndex].id
    }

    func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
        selectedTabId = tabs[prevIndex].id
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        selectedTabId = tabs[index].id
    }

    func selectLastTab() {
        guard let lastTab = tabs.last else { return }
        selectedTabId = lastTab.id
    }

    func newSplit(tabId: UUID, surfaceId: UUID, direction: SplitTree<TerminalSurface>.NewDirection) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.newSplit(from: surfaceId, direction: direction) != nil
    }

    func moveSplitFocus(tabId: UUID, surfaceId: UUID, direction: SplitTree<TerminalSurface>.FocusDirection) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.moveFocus(from: surfaceId, direction: direction)
    }

    func resizeSplit(tabId: UUID, surfaceId: UUID, direction: SplitTree<TerminalSurface>.Spatial.Direction, amount: UInt16) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.resizeSplit(from: surfaceId, direction: direction, amount: amount)
    }

    func equalizeSplits(tabId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        guard tab.splitTree.isSplit else { return false }
        tab.equalizeSplits()
        return true
    }

    func toggleSplitZoom(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        return tab.toggleZoom(on: surfaceId)
    }

    func closeSurface(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
        let tab = tabs[tabIndex]
        guard tab.closeSurface(surfaceId) else { return false }
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tabId, surfaceId: surfaceId)

        if tab.splitTree.isEmpty {
            if tabs.count > 1 {
                closeTab(tab)
            } else {
                let newSurface = TerminalSurface(
                    tabId: tab.id,
                    context: GHOSTTY_SURFACE_CONTEXT_TAB,
                    configTemplate: nil
                )
                tab.splitTree = SplitTree(view: newSurface)
                tab.focusSurface(newSurface.id)
            }
        }

        return true
    }
}

extension Notification.Name {
    static let ghosttyDidSetTitle = Notification.Name("ghosttyDidSetTitle")
    static let ghosttyDidFocusTab = Notification.Name("ghosttyDidFocusTab")
}
