import AppKit
import Bonsplit
import Foundation

/// User-visible selection and window state preserved across one mirror topology mutation.
@MainActor
struct RemoteTmuxMirrorMutationSnapshot {
    let selectedTabs: [(paneId: PaneID, tabId: TabID)]
    let focusedPaneId: PaneID?
    let tabManager: TabManager?
    let selectedWorkspaceId: UUID?
    let window: NSWindow?
    let wasWindowVisible: Bool
    let wasWindowKey: Bool
    let wasApplicationActive: Bool
    let previousKeyWindow: NSWindow?

    init(workspace: Workspace) {
        selectedTabs = workspace.bonsplitController.allPaneIds.compactMap { paneId in
            workspace.bonsplitController.selectedTab(inPane: paneId).map { (paneId, $0.id) }
        }
        focusedPaneId = workspace.bonsplitController.focusedPaneId
        tabManager = workspace.owningTabManager
        selectedWorkspaceId = tabManager?.selectedTabId
        window = tabManager?.window
        wasWindowVisible = window?.isVisible == true
        wasWindowKey = window?.isKeyWindow == true
        wasApplicationActive = NSApp.isActive
        previousKeyWindow = NSApp.keyWindow
    }

    func restore(in workspace: Workspace) {
        let selectedWorkspaceStillExists = selectedWorkspaceId.map { selectedWorkspaceId in
            tabManager?.tabs.contains(where: { $0.id == selectedWorkspaceId }) == true
        } ?? true
        if tabManager?.selectedTabId != selectedWorkspaceId, selectedWorkspaceStillExists {
            tabManager?.selectedTabId = selectedWorkspaceId
        }

        for selection in selectedTabs
        where workspace.bonsplitController.tabs(inPane: selection.paneId).contains(where: { $0.id == selection.tabId }) {
            workspace.bonsplitController.selectTab(selection.tabId)
        }
        if let focusedPaneId,
           workspace.bonsplitController.allPaneIds.contains(focusedPaneId) {
            workspace.bonsplitController.focusPane(focusedPaneId)
        }

        // A session-end lifecycle may legitimately discard the dedicated window;
        // never resurrect a window its manager no longer owns.
        guard let window, tabManager?.window === window else { return }
        // Ordering a window out is the supported way to make AppKit resign an
        // unexpected key window; `resignKeyWindow` is an override hook and must
        // not be invoked directly.
        if !wasWindowKey && window.isKeyWindow {
            window.orderOut(nil)
        }
        if wasWindowVisible && !window.isVisible {
            window.orderFront(nil)
        } else if !wasWindowVisible && window.isVisible {
            window.orderOut(nil)
        }
        if wasWindowKey {
            if !window.isKeyWindow { window.makeKey() }
        } else if let previousKeyWindow,
                  previousKeyWindow !== window,
                  previousKeyWindow.isVisible,
                  !previousKeyWindow.isKeyWindow {
            previousKeyWindow.makeKey()
        }
        if !wasApplicationActive && NSApp.isActive { NSApp.deactivate() }
    }

    func requiresReplacementFocus(in workspace: Workspace) -> Bool {
        guard wasWindowVisible,
              wasWindowKey,
              selectedWorkspaceId == workspace.id,
              tabManager?.window === window,
              let focusedPaneId,
              let selectedTabId = selectedTabs.first(where: { $0.paneId == focusedPaneId })?.tabId
        else { return false }
        return !workspace.bonsplitController.tabs(inPane: focusedPaneId).contains {
            $0.id == selectedTabId
        }
    }
}
