import AppKit
import WebKit

@available(macOS 15.4, *)
@MainActor
extension BrowserWebExtensionSupport {
    func noteWindowChanged(panelID: UUID, nativeWindow: NSWindow?) {
        if let panel = tabAdapters[panelID]?.panel {
            AppDelegate.shared?.noteRecoverableBrowserWebExtensionPanelRegistered(
                panelID: panelID,
                workspaceID: panel.workspaceId
            )
        }
        reconcileWindowOwnership(for: panelID, nativeWindow: nativeWindow)
    }

    func noteTabOrderChanged(panelIDs: [UUID], in nativeWindow: NSWindow) {
        let windowID = ObjectIdentifier(nativeWindow)
        let previousPanelIDs = orderedPanelIDs.filter { windowIDsByPanelID[$0] == windowID }
        let requestedPanelIDs = panelIDs.filter {
            tabAdapters[$0] != nil && windowIDsByPanelID[$0] == windowID
        }
        let requestedSet = Set(requestedPanelIDs)
        let nextPanelIDs = requestedPanelIDs + previousPanelIDs.filter { !requestedSet.contains($0) }
        guard nextPanelIDs != previousPanelIDs else { return }

        let insertionIndex = orderedPanelIDs.firstIndex { windowIDsByPanelID[$0] == windowID }
            ?? orderedPanelIDs.endIndex
        orderedPanelIDs.removeAll { windowIDsByPanelID[$0] == windowID }
        orderedPanelIDs.insert(contentsOf: nextPanelIDs, at: min(insertionIndex, orderedPanelIDs.endIndex))

        guard let windowAdapter = windowAdaptersByWindowID[windowID] else { return }
        for (newIndex, panelID) in nextPanelIDs.enumerated() {
            guard let oldIndex = previousPanelIDs.firstIndex(of: panelID),
                  oldIndex != newIndex,
                  openTabNotificationPanelIDs.contains(panelID),
                  let tab = tabAdapters[panelID] else {
                continue
            }
            controller.didMoveTab(tab, from: oldIndex, in: windowAdapter)
        }
    }

    func noteWindowClosed(_ nativeWindow: NSWindow) -> UUID? {
        let previouslyActivePanelID = activePanelID(in: nativeWindow)
        closeNativeWindow(
            withID: ObjectIdentifier(nativeWindow),
            ifOwnedBy: nativeWindow
        )
        return previouslyActivePanelID
    }

    func discardWindowOwnership(panelIDs: [UUID]) {
        let closingPanelIDs = Set(panelIDs)
        let affectedWindowIDs = Set(panelIDs.compactMap { windowIDsByPanelID[$0] })
        for windowID in affectedWindowIDs {
            let windowPanelIDs = orderedPanelIDs.filter { windowIDsByPanelID[$0] == windowID }
            if !windowPanelIDs.isEmpty,
               windowPanelIDs.allSatisfy(closingPanelIDs.contains) {
                closeNativeWindow(withID: windowID)
            }
        }
        for panelID in panelIDs {
            unregister(panelID: panelID)
        }
    }

    func noteUserOwnedPanelAdded(nativeWindow: NSWindow?, alongsidePanelIDs: [UUID]) {
        let nativeWindowAdapter = nativeWindow.flatMap {
            windowAdaptersByWindowID[ObjectIdentifier($0)]
        }
        let adapter = nativeWindowAdapter ?? alongsidePanelIDs.lazy.compactMap(windowAdapter(for:)).first
        adapter?.revokeExtensionCloseAuthority()
    }

    func noteActivated(panelID: UUID) {
        guard let adapter = tabAdapters[panelID] else { return }
        if windowIDsByPanelID[panelID] == nil {
            reconcileWindowOwnership(for: panelID)
        }
        guard let windowID = windowIDsByPanelID[panelID] else { return }

        let previousPanelID = activePanelIDsByWindow[windowID]
        let previous = previousPanelID.flatMap { tabAdapters[$0] }
        let previouslyFocusedPanelID = activePanelID
        activePanelIDsByWindow[windowID] = panelID
        let activatesFocusedWindow = windowAdaptersByWindowID[windowID]?.hostWindow?.isKeyWindow == true
        if activatesFocusedWindow {
            activePanelID = panelID
            lastFocusedNormalWindowID = windowID
        }

        if previousPanelID != panelID {
            controller.didActivateTab(adapter, previousActiveTab: previous)
        }
        refreshActionSnapshots(for: previousPanelID)
        if activatesFocusedWindow, previouslyFocusedPanelID != previousPanelID {
            refreshActionSnapshots(for: previouslyFocusedPanelID)
        }
        refreshActionSnapshots(for: panelID)
    }

    func noteWindowBecameKey(_ window: NSWindow) {
        let focusedWindow = focusedWebExtensionWindow(for: window)
        if focusedWindow is BrowserWebExtensionWindowAdapter {
            lastFocusedNormalWindowID = ObjectIdentifier(window)
        }
        if focusedWindow is BrowserWebExtensionWindowAdapter,
           let panelID = activePanelID(in: window),
           activePanelID != panelID {
            let previouslyFocusedPanelID = activePanelID
            activePanelID = panelID
            refreshActionSnapshots(for: previouslyFocusedPanelID)
            refreshActionSnapshots(for: panelID)
        } else if AppDelegate.shared?.isMainTerminalWindow(window) == true,
                  activePanelID != nil {
            let previouslyFocusedPanelID = activePanelID
            activePanelID = nil
            refreshActionSnapshots(for: previouslyFocusedPanelID)
        }
        notifyFocusedWindow(focusedWindow)
    }

    func notifyFocusedWindow(_ focusedWindow: (any WKWebExtensionWindow)?) {
        guard let popout = focusedWindow as? BrowserWebExtensionPopoutWindowController,
              let owningContext = popout.extensionContext else {
            controller.didFocusWindow(focusedWindow)
            return
        }
        for record in loadedRecordsInOrder {
            record.context.didFocusWindow(record.context === owningContext ? popout : nil)
        }
    }

    func focusedWebExtensionWindow(for keyWindow: NSWindow?) -> (any WKWebExtensionWindow)? {
        guard let keyWindow else { return nil }
        return webExtensionWindow(for: keyWindow)
    }

    func webExtensionWindow(for window: NSWindow) -> (any WKWebExtensionWindow)? {
        if let popout = popouts.first(where: { $0.window === window }) {
            return popout
        }
        guard let adapter = windowAdaptersByWindowID[ObjectIdentifier(window)],
              adapter.hostWindow === window else {
            return nil
        }
        guard activePanelID(in: window) != nil else { return nil }
        return adapter
    }

    func rememberActivePanel(_ panelID: UUID) {
        reconcileWindowOwnership(for: panelID)
        guard let windowID = windowIDsByPanelID[panelID] else { return }
        if activePanelIDsByWindow[windowID] == nil {
            activePanelIDsByWindow[windowID] = panelID
        }
    }

    func activePanelID(in window: NSWindow) -> UUID? {
        let windowID = ObjectIdentifier(window)
        if let rememberedPanelID = activePanelIDsByWindow[windowID],
           windowIDsByPanelID[rememberedPanelID] == windowID {
            return rememberedPanelID
        }
        activePanelIDsByWindow.removeValue(forKey: windowID)
        return nil
    }

    func orderedTabAdapters(in window: NSWindow) -> [BrowserWebExtensionTabAdapter] {
        orderedTabAdapters(inWindowID: ObjectIdentifier(window))
    }

    func orderedTabAdapters(inWindowID windowID: ObjectIdentifier) -> [BrowserWebExtensionTabAdapter] {
        orderedPanelIDs.compactMap { panelID in
            guard windowIDsByPanelID[panelID] == windowID else { return nil }
            return tabAdapters[panelID]
        }
    }

    func activeTabAdapter(in window: NSWindow) -> BrowserWebExtensionTabAdapter? {
        activePanelID(in: window).flatMap { tabAdapters[$0] }
    }

    func indexInWindow(of panelID: UUID) -> Int {
        guard let windowID = windowIDsByPanelID[panelID] else { return NSNotFound }
        return orderedTabAdapters(inWindowID: windowID)
            .firstIndex(where: { $0.panel?.id == panelID }) ?? NSNotFound
    }

    func isPanelActiveInWindow(_ panelID: UUID) -> Bool {
        guard let windowID = windowIDsByPanelID[panelID] else { return false }
        return activePanelIDsByWindow[windowID] == panelID
    }

    func windowAdapter(for panelID: UUID) -> BrowserWebExtensionWindowAdapter? {
        guard let windowID = windowIDsByPanelID[panelID],
              let adapter = windowAdaptersByWindowID[windowID],
              adapter.hostWindow != nil else {
            return nil
        }
        return adapter
    }

    var normalWindowAdapters: [BrowserWebExtensionWindowAdapter] {
        var seen = Set<ObjectIdentifier>()
        return orderedPanelIDs.compactMap { panelID in
            guard let windowID = windowIDsByPanelID[panelID],
                  seen.insert(windowID).inserted else {
                return nil
            }
            guard let adapter = windowAdaptersByWindowID[windowID],
                  adapter.hostWindow != nil else {
                return nil
            }
            return adapter
        }
    }

    var normalWindowAdaptersInFocusOrder: [BrowserWebExtensionWindowAdapter] {
        let adapters = normalWindowAdapters
        guard let lastFocusedNormalWindowID,
              let focusedIndex = adapters.firstIndex(where: {
                  $0.hostWindow.map(ObjectIdentifier.init) == lastFocusedNormalWindowID
              }), focusedIndex != adapters.startIndex else {
            return adapters
        }
        var ordered = adapters
        let focused = ordered.remove(at: focusedIndex)
        ordered.insert(focused, at: ordered.startIndex)
        return ordered
    }

    func hostWindow(for panelID: UUID) -> NSWindow? {
        guard let panel = tabAdapters[panelID]?.panel else { return nil }
        if let owner = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelID,
            preferredWorkspaceId: panel.workspaceId
        ) {
            return owner.tabManager.window
        }
        if let dock = DockSplitStore.liveStores.first(where: { $0.containsPanel(panelID) }) {
            return AppDelegate.shared?.dockReferenceTabManager(for: dock)?.window
        }
        return panel.webView.window
    }

    private func reconcileWindowOwnership(for panelID: UUID, nativeWindow: NSWindow? = nil) {
        guard let tab = tabAdapters[panelID],
              let window = nativeWindow ?? hostWindow(for: panelID) else { return }
        let newWindowID = ObjectIdentifier(window)
        if let existingAdapter = windowAdaptersByWindowID[newWindowID],
           existingAdapter.hostWindow == nil {
            closeNativeWindow(withID: newWindowID)
        }
        let oldWindowID = windowIDsByPanelID[panelID]
        if oldWindowID == newWindowID {
            let (_, created) = ensureWindowAdapter(for: window)
            if created, let adapter = windowAdaptersByWindowID[newWindowID] {
                controller.didOpenWindow(adapter)
                synchronizeKeyWindow(
                    adapter,
                    windowID: newWindowID,
                    window: window,
                    notifyFocus: true
                )
            }
            return
        }

        let oldIndex = oldWindowID.flatMap { oldWindowID in
            orderedTabAdapters(inWindowID: oldWindowID)
                .firstIndex(where: { $0.panel?.id == panelID })
        } ?? 0
        let oldWindowAdapter = oldWindowID.flatMap { windowAdaptersByWindowID[$0] }
        let wasActiveInOldWindow = oldWindowID.flatMap { activePanelIDsByWindow[$0] } == panelID

        let (newWindowAdapter, created) = ensureWindowAdapter(for: window)
        if created {
            controller.didOpenWindow(newWindowAdapter)
        }
        windowIDsByPanelID[panelID] = newWindowID
        newWindowAdapter.notePanelAdded(panelID)
        if activePanelIDsByWindow[newWindowID] == nil {
            activePanelIDsByWindow[newWindowID] = panelID
        }

        guard let oldWindowID else {
            if openTabNotificationPanelIDs.insert(panelID).inserted {
                controller.didOpenTab(tab)
            } else {
                controller.didMoveTab(tab, from: 0, in: nil)
            }
            synchronizeKeyWindow(
                newWindowAdapter,
                windowID: newWindowID,
                window: window,
                notifyFocus: created
            )
            return
        }
        controller.didMoveTab(tab, from: oldIndex, in: oldWindowAdapter)
        oldWindowAdapter?.notePanelRemoved(panelID)

        let remainingAdapters = orderedTabAdapters(inWindowID: oldWindowID)
        if wasActiveInOldWindow {
            activePanelIDsByWindow.removeValue(forKey: oldWindowID)
            if activePanelID == panelID {
                activePanelID = nil
            }
        }

        synchronizeKeyWindow(
            newWindowAdapter,
            windowID: newWindowID,
            window: window,
            notifyFocus: created
        )
        guard remainingAdapters.isEmpty else { return }
        removeWindowAdapter(oldWindowAdapter, withID: oldWindowID)
    }

    private func synchronizeKeyWindow(
        _ adapter: BrowserWebExtensionWindowAdapter,
        windowID: ObjectIdentifier,
        window: NSWindow,
        notifyFocus: Bool
    ) {
        guard window.isKeyWindow else { return }
        lastFocusedNormalWindowID = windowID
        let previouslyFocusedPanelID = activePanelID
        activePanelID = activePanelIDsByWindow[windowID]
        refreshActionSnapshots(for: previouslyFocusedPanelID)
        refreshActionSnapshots(for: activePanelID)
        if notifyFocus {
            controller.didFocusWindow(adapter)
        }
    }

    private func closeNativeWindow(
        withID windowID: ObjectIdentifier,
        ifOwnedBy expectedWindow: NSWindow? = nil
    ) {
        let adapter = windowAdaptersByWindowID[windowID]
        if let expectedWindow, adapter?.hostWindow !== expectedWindow {
            return
        }

        let closingPanelIDs = orderedPanelIDs.filter { windowIDsByPanelID[$0] == windowID }
        let previouslyFocusedPanelID = activePanelID
        for panelID in closingPanelIDs {
            pendingTabMetadataPanelIDs.remove(panelID)
            if let tab = tabAdapters[panelID],
               openTabNotificationPanelIDs.remove(panelID) != nil {
                controller.didCloseTab(tab, windowIsClosing: true)
            }
            windowIDsByPanelID.removeValue(forKey: panelID)
            refreshActionSnapshots(for: panelID)
        }
        if let globallyActivePanelID = activePanelID,
           closingPanelIDs.contains(globallyActivePanelID) {
            activePanelID = nil
            refreshActionSnapshots(for: previouslyFocusedPanelID)
        }
        if let adapter {
            removeWindowAdapter(adapter, withID: windowID)
        }
    }

    func removeWindowAdapter(
        _ adapter: BrowserWebExtensionWindowAdapter?,
        withID windowID: ObjectIdentifier
    ) {
        let wasFocused = adapter?.hostWindow?.isKeyWindow == true
        windowAdaptersByWindowID.removeValue(forKey: windowID)
        activePanelIDsByWindow.removeValue(forKey: windowID)
        if lastFocusedNormalWindowID == windowID {
            lastFocusedNormalWindowID = nil
        }
        if wasFocused {
            notifyFocusedWindow(nil)
        }
        if let adapter {
            controller.didCloseWindow(adapter)
        }
    }

    private func ensureWindowAdapter(
        for window: NSWindow
    ) -> (adapter: BrowserWebExtensionWindowAdapter, created: Bool) {
        let windowID = ObjectIdentifier(window)
        if let adapter = windowAdaptersByWindowID[windowID], adapter.hostWindow === window {
            return (adapter, false)
        }
        let adapter = BrowserWebExtensionWindowAdapter(support: self, hostWindow: window)
        windowAdaptersByWindowID[windowID] = adapter
        return (adapter, true)
    }
}
