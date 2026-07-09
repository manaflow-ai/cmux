import AppKit
import Bonsplit
import CmuxWorkspaces
import Foundation

/// `Workspace`'s conformance to ``WorkspaceContextMenuHosting``: the irreducible
/// app-coupled effects the package ``WorkspaceContextMenuCoordinator`` forwards
/// back into the god object for the bonsplit tab context-menu commands.
///
/// Each witness is the body that previously lived inline in the corresponding
/// `Workspace` private helper (`copyIdentifiersToPasteboard`, `promptRenamePanel`,
/// `showMoveTabFailureAlert`, and the `newTerminalSurface`/`newBrowserSurface`/
/// `reorderSurface`/`AppDelegate` move calls the create/move helpers issued). The
/// coordinator owns the slicing, index math, and dispatch; this conformance owns
/// the panel-registry, NSAlert, clipboard, and `AppDelegate` reach.
extension Workspace: WorkspaceContextMenuHosting {
    // `workspaceId`, `panelId(forSurfaceId:)`, and `paneId(forPanelId:)` are
    // already declared on `Workspace` (the first two via the
    // `WorkspaceContextMenuHosting`-shared `SplitMoveReorderHosting` witnesses),
    // satisfying those requirements directly.

    // MARK: Close

    // `closeTabsFromContextMenu(_:skipPinned:)` is already declared on
    // `Workspace` with this exact signature, satisfying the requirement directly.

    // MARK: Surface creation / reorder

    // `insertionIndexToRight(of:inPane:)` is already declared on `Workspace`
    // with this exact signature, satisfying the requirement directly.

    func newTerminalSurface(
        inPane paneId: PaneID,
        workingDirectoryFallbackSourcePanelId sourcePanelId: UUID?
    ) -> UUID? {
        newTerminalSurface(
            inPane: paneId,
            focus: true,
            inheritWorkingDirectoryFallback: true,
            workingDirectoryFallbackSourcePanelId: sourcePanelId
        )?.id
    }

    func newBrowserSurface(
        inPane paneId: PaneID,
        inheritingProfileFromPanelId anchorPanelId: UUID?
    ) -> UUID? {
        let preferredProfileID = anchorPanelId.flatMap { browserPanel(for: $0)?.profileID }
        return newBrowserSurface(
            inPane: paneId,
            url: nil,
            focus: true,
            preferredProfileID: preferredProfileID
        )?.id
    }

    func reorderSurface(panelId: UUID, toIndex index: Int) {
        _ = reorderSurface(panelId: panelId, toIndex: index, focus: true)
    }

    // MARK: Rename (NSAlert)

    func presentRenamePrompt(tabId: TabID) {
        guard let panelId = panelIdFromSurfaceId(tabId),
              let panel = panels[panelId] else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameTab.title", defaultValue: "Rename Tab")
        alert.informativeText = String(localized: "alert.renameTab.message", defaultValue: "Enter a custom name for this tab.")
        let currentTitle = panelCustomTitles[panelId] ?? panelTitles[panelId] ?? panel.displayTitle
        let input = NSTextField(string: currentTitle)
        input.placeholderString = String(localized: "alert.renameTab.placeholder", defaultValue: "Tab name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameTab.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        setPanelCustomTitle(panelId: panelId, title: input.stringValue)
    }

    // MARK: Clipboard

    func copySurfaceIdentifiersToPasteboard(surfaceId: UUID) {
        let paneId = paneId(forPanelId: surfaceId)?.id
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeWorkspacePaneSurfaceIdentifiers(
                workspaceId: id,
                paneId: paneId,
                surfaceId: surfaceId,
                includeRefs: true
            )
        )
    }

    // MARK: Cross-workspace move (AppDelegate)

    func canMoveSurfaceToNewWorkspace(panelId: UUID) -> Bool {
        hostEnvironment?.environment.mainWindowRouter.canMoveSurfaceToNewWorkspace(panelId: panelId) ?? false
    }

    func workspaceMoveTargets(forBonsplitTab tabId: TabID) -> [WorkspaceContextMoveTarget] {
        guard let mainWindowRouter = hostEnvironment?.environment.mainWindowRouter else { return [] }
        return mainWindowRouter.workspaceMoveTargets(forBonsplitTab: tabId.uuid).map { target in
            WorkspaceContextMoveTarget(workspaceId: target.workspaceId, label: target.label)
        }
    }

    func moveSurfaceToNewWorkspace(panelId: UUID) -> Bool {
        guard let mainWindowRouter = hostEnvironment?.environment.mainWindowRouter else { return false }
        return mainWindowRouter.moveSurfaceToNewWorkspace(
            panelId: panelId,
            focus: true,
            focusWindow: false
        ) != nil
    }

    func moveSurface(panelId: UUID, toWorkspace workspaceId: UUID) -> Bool {
        guard let app = AppDelegate.shared else { return false }
        return app.moveSurface(
            panelId: panelId,
            toWorkspace: workspaceId,
            focus: true,
            focusWindow: true
        )
    }

    // MARK: Move-failure alert (NSAlert)

    func presentMoveFailureAlert() {
        let failure = NSAlert()
        failure.alertStyle = .warning
        failure.messageText = String(localized: "alert.moveTab.failed.title", defaultValue: "Move Failed")
        failure.informativeText = String(localized: "alert.moveTab.failed.message", defaultValue: "cmux could not move this tab to the selected destination.")
        failure.addButton(withTitle: String(localized: "alert.ok", defaultValue: "OK"))
        _ = failure.runModal()
    }
}
