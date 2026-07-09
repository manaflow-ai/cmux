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
        previousKeyWindow = NSApp.keyWindow
    }

    func restore(in workspace: Workspace) {
        if let selectedWorkspaceId,
           tabManager?.selectedTabId != selectedWorkspaceId,
           tabManager?.tabs.contains(where: { $0.id == selectedWorkspaceId }) == true {
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
        if wasWindowVisible != window.isVisible {
            if wasWindowVisible {
                window.orderFront(nil)
            } else {
                window.orderOut(nil)
            }
        }
        if wasWindowKey {
            if !window.isKeyWindow { window.makeKey() }
        } else if let previousKeyWindow,
                  previousKeyWindow !== window,
                  previousKeyWindow.isVisible,
                  !previousKeyWindow.isKeyWindow {
            previousKeyWindow.makeKey()
        } else if window.isKeyWindow {
            window.resignKey()
        }
    }
}
