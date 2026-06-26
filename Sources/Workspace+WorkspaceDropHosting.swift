import CmuxWorkspaces
import Bonsplit
import Foundation

/// `Workspace` is the live host for its `WorkspaceDropCoordinator`. The
/// coordinator (in `CmuxWorkspaces`) owns the external-drop *routing* the legacy
/// `Workspace` god object kept inline next to its surface-creation machinery: the
/// `handleExternalTabDrop` dispatch (session-index drag → new terminal,
/// file-preview drag → file surface, otherwise a cross-window tab move) and the
/// per-drop insert/split branching for the session and file paths. Everything
/// that routing drives on the live window is irreducibly app-coupled, so each
/// member here reproduces one read or mutation the legacy inline drop bodies
/// performed on `self`: consuming the process-wide drag registries, the
/// brand-new terminal / file-preview surface creation, the live pane lookup for
/// a freshly created panel, the cross-window `AppDelegate.moveBonsplitTab` call,
/// and the DEBUG `split.externalDrop.begin`/`.end` tracing. The coordinator is
/// held by `Workspace` and references this host weakly, so there is no retain
/// cycle.
///
/// This mirrors the sibling `Workspace+AgentForkHosting.swift` pattern: the
/// lifted coordinator's live seam conformance lives in its own app-target file so
/// `Workspace.swift` drains the routing instead of trading it for inline seam
/// glue.
extension Workspace: WorkspaceDropHosting {
    // `CreatedPanel` is inferred as `any Panel` from `splitFileSurface` and
    // `resolvePane(forCreatedPanel:)` below.

    // MARK: - Drag registry consumption

    func consumeSessionDrop(tabId: UUID) -> WorkspaceSessionDropPayload? {
        // Mirrors the legacy `SessionDragRegistry.shared.consume(id:)` plus the
        // `guard let resumeCommand = entry.resumeCommand` gate at the top of
        // `handleSessionDrop`: a registered entry with no resume command produced
        // `false` there, which the coordinator reproduces by treating a `nil`
        // payload as "not a session drop" and falling through. (A consumed
        // file-preview entry could only follow a missing session entry, so the
        // ordering is unchanged: a session entry that lacked a resume command was
        // already consumed and the legacy body returned `false` before the
        // file-preview check; here it is consumed and yields `nil`, after which
        // the coordinator runs the file-preview consume next, exactly as before.)
        guard let entry = SessionDragRegistry.shared.consume(id: tabId) else { return nil }
        guard let resumeCommand = entry.resumeCommand else { return nil }
        return WorkspaceSessionDropPayload(
            resumeCommand: resumeCommand,
            resumeWorkingDirectory: entry.resumeWorkingDirectory
        )
    }

    func consumeFileDrop(tabId: UUID) -> WorkspaceFileDropPayload? {
        guard let entry = FilePreviewDragRegistry.shared.consume(id: tabId) else { return nil }
        return WorkspaceFileDropPayload(filePath: entry.filePath)
    }

    // MARK: - Session surface creation

    func createSessionInsertTerminal(
        inPane paneId: PaneID,
        workingDirectory: String?,
        initialInput: String
    ) -> Bool {
        let panel = newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: workingDirectory,
            initialInput: initialInput
        )
        return panel != nil
    }

    func createSessionSplitTerminal(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        workingDirectory: String?,
        initialInput: String
    ) -> Bool {
        let panel = splitPaneWithNewTerminal(
            targetPane: paneId,
            orientation: orientation,
            insertFirst: insertFirst,
            workingDirectory: workingDirectory,
            initialInput: initialInput
        )
        return panel != nil
    }

    // MARK: - File surface creation

    func openFileSurfaces(
        inPane paneId: PaneID,
        filePaths: [String],
        targetIndex: Int?
    ) -> Bool {
        !openFileSurfaces(
            inPane: paneId,
            filePaths: filePaths,
            focus: true,
            targetIndex: targetIndex
        ).isEmpty
    }

    func openAdditionalFileSurfaces(
        inPane paneId: PaneID,
        filePaths: [String]
    ) {
        _ = openFileSurfaces(
            inPane: paneId,
            filePaths: filePaths,
            focus: true
        )
    }

    func splitFileSurface(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> (any Panel)? {
        splitPaneWithFileSurface(
            targetPane: paneId,
            orientation: orientation,
            insertFirst: insertFirst,
            filePath: filePath
        )
    }

    func resolvePane(forCreatedPanel panel: any Panel) -> PaneID? {
        paneId(forPanelId: panel.id)
    }

    // MARK: - Cross-window tab move

    func moveExternalTab(
        tabId: UUID,
        sourcePaneId: PaneID,
        destination: BonsplitController.ExternalTabDropRequest.Destination,
        targetPane: PaneID,
        targetIndex: Int?,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)?
    ) -> Bool {
        // Reproduces the legacy `handleExternalTabDrop` fall-through tail in its
        // exact order: the `guard let app` early-out emits no trace, the begin
        // trace precedes the move, the end trace follows it.
        guard let app = AppDelegate.shared else { return false }
#if DEBUG
        let dropStart = ProcessInfo.processInfo.systemUptime
        let destinationLabel: String
        switch destination {
        case .insert(let paneId, let index):
            destinationLabel = "insert pane=\(paneId.id.uuidString.prefix(5)) index=\(index.map(String.init) ?? "nil")"
        case .split(let paneId, let orientation, let insertFirst):
            destinationLabel = "split pane=\(paneId.id.uuidString.prefix(5)) orientation=\(orientation.rawValue) insertFirst=\(insertFirst ? 1 : 0)"
        }
        cmuxDebugLog(
            "split.externalDrop.begin ws=\(id.uuidString.prefix(5)) tab=\(tabId.uuidString.prefix(5)) " +
            "sourcePane=\(sourcePaneId.id.uuidString.prefix(5)) destination=\(destinationLabel)"
        )
#endif
        let moved = app.moveBonsplitTab(
            tabId: tabId,
            toWorkspace: id,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget,
            focus: true,
            focusWindow: true
        )
#if DEBUG
        cmuxDebugLog(
            "split.externalDrop.end ws=\(id.uuidString.prefix(5)) tab=\(tabId.uuidString.prefix(5)) " +
            "moved=\(moved ? 1 : 0) elapsedMs=\(debugElapsedMs(since: dropStart))"
        )
#endif
        return moved
    }
}
