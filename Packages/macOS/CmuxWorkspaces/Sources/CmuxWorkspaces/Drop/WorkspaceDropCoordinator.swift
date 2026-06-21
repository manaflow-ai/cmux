public import Foundation
public import Bonsplit

/// Routes an external drop onto a workspace's split layout to the right surface
/// creation, for one workspace window.
///
/// This `@MainActor` coordinator is the lifted home of the drop *routing* the
/// app-target `Workspace` god object kept inline next to its surface-creation
/// machinery: the top-level `handleExternalTabDrop` dispatch (session-index drag
/// → new terminal, file-preview drag → file surface, otherwise a cross-window
/// tab move) and the per-drop `Destination` branching for the session
/// (`handleSessionDrop`) and file (`handleFilePreviewDrop` /
/// `handleExternalFileDrop`) paths. The routing is pure dispatch over value
/// types; every live operation it drives (registry consumption, surface
/// creation, the live pane lookup, the cross-window move, DEBUG tracing) is
/// reached through ``WorkspaceDropHosting``, conformed by `Workspace` and
/// injected via ``attach(host:)``.
///
/// `Workspace` owns one instance and forwards each former method through a
/// one-line forward, so every external call site (the bonsplit
/// `onExternalTabDrop` / `onExternalFileDrop` handlers, the browser/terminal
/// pane drop target views, and the portal pane drop) stays byte-identical.
///
/// `@MainActor` because every drop originates on the main actor (a drag-and-drop
/// gesture resolving against the live bonsplit tree and `TabManager`), so
/// co-locating the routing with its callers keeps the forwards plain calls with
/// no bridging.
@MainActor
public final class WorkspaceDropCoordinator<Host: WorkspaceDropHosting> {
    /// The file-split surface type, taken from the host (app target's
    /// `any Panel`).
    public typealias CreatedPanel = Host.CreatedPanel

    private weak var host: Host?

    /// Creates a coordinator. Call ``attach(host:)`` at the composition point
    /// before any drop is routed.
    public init() {}

    /// Injects the live-workspace seam. Set before any drop routing runs so the
    /// registry reads, surface creation, and side effects reach the workspace.
    public func attach(host: Host) {
        self.host = host
    }

    // MARK: - Top-level dispatch

    /// Routes an external bonsplit tab drop, mirroring the legacy
    /// `Workspace.handleExternalTabDrop(_:)` exactly.
    ///
    /// A session-index drag and a file-preview drag both encode a `UUID` in the
    /// bonsplit tab payload, so the coordinator first asks the host to consume
    /// each registry for `request.tabId`; a hit routes to a brand-new surface at
    /// the destination instead of moving an existing tab. When neither registry
    /// has the id, it falls through to a cross-window tab move, decomposing the
    /// destination into the `(targetPane, targetIndex, splitTarget)` the move
    /// takes, exactly as the legacy `switch request.destination` did, and brackets
    /// the move with the DEBUG begin/end trace.
    @discardableResult
    public func handleExternalTabDrop(
        _ request: BonsplitController.ExternalTabDropRequest
    ) -> Bool {
        guard let host else { return false }

        // Session-index drag → spawn a brand new terminal at the destination
        // instead of moving an existing tab.
        if let payload = host.consumeSessionDrop(tabId: request.tabId.uuid) {
            return handleSessionDrop(payload: payload, destination: request.destination)
        }
        if let payload = host.consumeFileDrop(tabId: request.tabId.uuid) {
            return handleFileDrop(payload: payload, destination: request.destination)
        }

        let targetPane: PaneID
        let targetIndex: Int?
        let splitTarget: (orientation: SplitOrientation, insertFirst: Bool)?

        switch request.destination {
        case .insert(let paneId, let index):
            targetPane = paneId
            targetIndex = index
            splitTarget = nil
        case .split(let paneId, let orientation, let insertFirst):
            targetPane = paneId
            targetIndex = nil
            splitTarget = (orientation, insertFirst)
        }

        // The host owns the order-sensitive app-coupled tail (the
        // `guard let AppDelegate.shared` early-out that emits no trace, the
        // begin/end DEBUG traces, and the `moveBonsplitTab` call) so the legacy
        // ordering is preserved exactly; the coordinator hands it the decomposed
        // destination plus the originals the begin trace formats.
        return host.moveExternalTab(
            tabId: request.tabId.uuid,
            sourcePaneId: request.sourcePaneId,
            destination: request.destination,
            targetPane: targetPane,
            targetIndex: targetIndex,
            splitTarget: splitTarget
        )
    }

    // MARK: - Session drop

    /// Routes a resolved session-index drop, mirroring the legacy
    /// `Workspace.handleSessionDrop(entry:destination:)` exactly.
    ///
    /// The legacy body launched the resumed session with the resume command plus
    /// a trailing newline; the coordinator appends that newline here and lets the
    /// host create the terminal (insert) or split-then-create (split).
    @discardableResult
    public func handleSessionDrop(
        payload: WorkspaceSessionDropPayload,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        guard let host else { return false }
        let inputWithReturn = payload.resumeCommand + "\n"
        switch destination {
        case .insert(let paneId, _):
            return host.createSessionInsertTerminal(
                inPane: paneId,
                workingDirectory: payload.resumeWorkingDirectory,
                initialInput: inputWithReturn
            )
        case .split(let paneId, let orientation, let insertFirst):
            return host.createSessionSplitTerminal(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                workingDirectory: payload.resumeWorkingDirectory,
                initialInput: inputWithReturn
            )
        }
    }

    // MARK: - File-preview drop

    /// Routes a resolved file-preview drag drop, mirroring the legacy
    /// `Workspace.handleFilePreviewDrop(entry:destination:)` exactly: the single
    /// file is opened into the destination pane (insert) or placed in a fresh
    /// split (split).
    @discardableResult
    public func handleFileDrop(
        payload: WorkspaceFileDropPayload,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        guard let host else { return false }
        switch destination {
        case .insert(let paneId, let index):
            return host.openFileSurfaces(
                inPane: paneId,
                filePaths: [payload.filePath],
                targetIndex: index
            )
        case .split(let paneId, let orientation, let insertFirst):
            return host.splitFileSurface(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: payload.filePath
            ) != nil
        }
    }

    // MARK: - Finder external-file drop

    /// Routes a Finder external-file drop, mirroring the legacy
    /// `Workspace.handleExternalFileDrop(_:)` exactly.
    ///
    /// The legacy body filtered the dropped `URL`s to file URLs and projected
    /// each into a file-preview entry; the coordinator does that pure filter and
    /// projection over ``WorkspaceFileDropPayload``, returning `false` when none
    /// survive. The insert branch opens every file at the target index; the split
    /// branch splits the first file into a fresh pane, then opens the remaining
    /// files into the pane that split produced (falling back to the source pane
    /// when the created panel is not yet in a pane), exactly as the legacy
    /// `paneId(forPanelId: firstPanel.id) ?? sourcePaneId` did.
    @discardableResult
    public func handleExternalFileDrop(
        _ request: BonsplitController.ExternalFileDropRequest
    ) -> Bool {
        guard let host else { return false }

        let payloads = request.urls
            .filter(\.isFileURL)
            .map { WorkspaceFileDropPayload(filePath: $0.path) }
        guard !payloads.isEmpty else { return false }

        switch request.destination {
        case .insert(let paneId, let index):
            return host.openFileSurfaces(
                inPane: paneId,
                filePaths: payloads.map(\.filePath),
                targetIndex: index
            )

        case .split(let sourcePaneId, let orientation, let insertFirst):
            guard let first = payloads.first,
                  let firstPanel = host.splitFileSurface(
                    targetPane: sourcePaneId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    filePath: first.filePath
                  ) else {
                return false
            }

            let targetPane = host.resolvePane(forCreatedPanel: firstPanel) ?? sourcePaneId
            host.openAdditionalFileSurfaces(
                inPane: targetPane,
                filePaths: payloads.dropFirst().map(\.filePath)
            )
            return true
        }
    }
}
