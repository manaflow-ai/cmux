import AppKit
import Foundation

/// Opens Feed through the same feature gate for workspace and pane entrypoints.
@MainActor
final class FeedOpeningCoordinator {
    private let isEnabled: () -> Bool

    init(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
    }

    @discardableResult
    func openPinnedWorkspace(in tabManager: TabManager) -> Workspace? {
        guard isEnabled() else {
            NSSound.beep()
            return nil
        }

        let workspace = tabManager.addWorkspace(
            title: String(localized: "rightSidebar.mode.feed", defaultValue: "Feed"),
            initialSurface: .feed,
            inheritWorkingDirectory: false,
            select: true,
            autoWelcomeIfNeeded: false,
            allowTextBoxFocusDefault: false
        )
        tabManager.setPinned(workspace, pinned: true)
        return workspace
    }

    @discardableResult
    func openPane(in workspace: Workspace) -> RightSidebarToolPanel? {
        guard isEnabled(),
              let paneID = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
            NSSound.beep()
            return nil
        }

        workspace.clearSplitZoom()
        return workspace.openOrFocusRightSidebarToolSurface(
            inPane: paneID,
            mode: .feed,
            focus: true
        )
    }
}
