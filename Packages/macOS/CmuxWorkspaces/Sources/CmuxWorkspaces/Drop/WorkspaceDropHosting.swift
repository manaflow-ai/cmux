public import Foundation
public import Bonsplit

/// The live-workspace operations ``WorkspaceDropCoordinator`` reaches back into
/// when it routes an external tab / session / file-preview / Finder-file drop to
/// a freshly created surface.
///
/// ``WorkspaceDropCoordinator`` owns the *routing* the legacy `Workspace` god
/// object kept inline (`handleExternalTabDrop`, `handleSessionDrop`,
/// `handleFilePreviewDrop`, `handleExternalFileDrop`): which drag registry a
/// dropped bonsplit tab id resolves to, which `Destination` branch (insert vs
/// split) each drop takes, the `Destination`-to-`(targetPane, targetIndex,
/// splitTarget)` decomposition the cross-window tab move needs, the Finder-URL
/// filter-and-project, and the multi-file "split the first, then open the rest in
/// the resulting pane" sequencing. None of that touches live state; it is pure
/// dispatch over value types.
///
/// Everything the routing drives, however, is irreducibly app-coupled and stays
/// on the app-target `Workspace` behind this seam: consuming the process-wide
/// drag registries, constructing the app's `TerminalPanel` / file-preview
/// surfaces (the Wave-4 god-model decomposition keeps surface creation
/// app-side), reading the live pane that holds a freshly created panel, and the
/// cross-window `AppDelegate.moveBonsplitTab` call. The host owns all of that;
/// the coordinator owns only the decision of which path to take.
///
/// Pane ids are Bonsplit's `PaneID` (the same value type the app target uses
/// directly, with no app-side typealias), so the seam speaks it without an
/// associated type. The one associated type is `CreatedPanel`, the file-split
/// surface the host returns (app target's `any Panel`), used only to resolve the
/// destination pane for the remaining files of a multi-file Finder drop; keeping
/// it abstract leaves the package free of the concrete app surface type so the
/// graph stays acyclic. The app target's `Workspace` conforms and is injected
/// via ``WorkspaceDropCoordinator/attach(host:)``; every method mirrors one read
/// or mutation the legacy method bodies performed, so the move is byte-faithful.
@MainActor
public protocol WorkspaceDropHosting: AnyObject {
    /// The file-split surface a split file-preview/markdown drop returns (app
    /// target's `any Panel`), used to resolve the destination pane for the
    /// remaining files of a multi-file Finder drop (legacy
    /// `splitPaneWithFileSurface(...)`'s `any Panel?` result).
    associatedtype CreatedPanel

    // MARK: - Drag registry consumption

    /// Consumes the session-index drag registry entry for `tabId` and projects it
    /// into the Sendable payload, or `nil` when no entry is registered (or the
    /// entry has no resume command). Mirrors the legacy
    /// `SessionDragRegistry.shared.consume(id:)` followed by the
    /// `guard let resumeCommand = entry.resumeCommand` gate at the top of
    /// `handleSessionDrop` (the host folds that guard in, returning `nil` so the
    /// coordinator's session branch matches the legacy early `return false`).
    func consumeSessionDrop(tabId: UUID) -> WorkspaceSessionDropPayload?

    /// Consumes the file-preview drag registry entry for `tabId` and projects its
    /// file path into the Sendable payload, or `nil` when no entry is registered.
    /// Mirrors the legacy `FilePreviewDragRegistry.shared.consume(id:)`.
    func consumeFileDrop(tabId: UUID) -> WorkspaceFileDropPayload?

    // MARK: - Session surface creation

    /// Creates a brand-new terminal at `paneId` for a session drop, returning
    /// whether one was created. Mirrors the legacy `handleSessionDrop` `.insert`
    /// branch: `newTerminalSurface(inPane:focus:true, workingDirectory:,
    /// initialInput:) != nil`.
    func createSessionInsertTerminal(
        inPane paneId: PaneID,
        workingDirectory: String?,
        initialInput: String
    ) -> Bool

    /// Splits `paneId` and places a brand-new terminal in the resulting pane for
    /// a session drop, returning whether one was created. Mirrors the legacy
    /// `handleSessionDrop` `.split` branch: `splitPaneWithNewTerminal(targetPane:,
    /// orientation:, insertFirst:, workingDirectory:, initialInput:) != nil`.
    func createSessionSplitTerminal(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        workingDirectory: String?,
        initialInput: String
    ) -> Bool

    // MARK: - File surface creation

    /// Opens `filePaths` as focused file-preview surfaces inserted into `paneId`
    /// at `targetIndex`, returning whether any surface was opened. Mirrors the
    /// legacy `!openFileSurfaces(inPane:filePaths:focus:true, targetIndex:).isEmpty`
    /// used by both the file-preview and external-file insert branches.
    func openFileSurfaces(
        inPane paneId: PaneID,
        filePaths: [String],
        targetIndex: Int?
    ) -> Bool

    /// Opens `filePaths` as focused file-preview surfaces appended to `paneId`
    /// (no target index), discarding the result. Mirrors the legacy
    /// `_ = openFileSurfaces(inPane:filePaths:focus:true)` that places the
    /// remaining files of a multi-file Finder drop into the split's pane.
    func openAdditionalFileSurfaces(
        inPane paneId: PaneID,
        filePaths: [String]
    )

    /// Splits `paneId` and places a file-preview (or markdown) surface for
    /// `filePath` in the resulting pane, returning the created surface or `nil`
    /// on failure. Mirrors the legacy private `splitPaneWithFileSurface(targetPane:,
    /// orientation:, insertFirst:, filePath:)`, which routes to
    /// `splitPaneWithMarkdown` for markdown-like paths and `splitPaneWithFilePreview`
    /// otherwise. Surface creation stays app-side (Wave-4), so the host owns the body.
    func splitFileSurface(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> CreatedPanel?

    /// The live pane currently holding `panel`, or `nil` when it is not in any
    /// pane. Mirrors the legacy `paneId(forPanelId: firstPanel.id)` lookup the
    /// multi-file Finder split uses to place the remaining files beside the first.
    func resolvePane(forCreatedPanel panel: CreatedPanel) -> PaneID?

    // MARK: - Cross-window tab move

    /// Moves an existing bonsplit tab into this workspace at the resolved
    /// destination, returning whether the move was handled.
    ///
    /// Mirrors the legacy `handleExternalTabDrop`'s fall-through path byte-for-byte
    /// and in its exact order: `guard let app = AppDelegate.shared else { return
    /// false }` (so a `nil` `AppDelegate` returns `false` and emits NO trace
    /// lines), then the DEBUG `split.externalDrop.begin` trace, then
    /// `app.moveBonsplitTab(tabId:toWorkspace:self.id, targetPane:, targetIndex:,
    /// splitTarget:, focus:true, focusWindow:true)`, then the DEBUG
    /// `split.externalDrop.end` trace, then the moved result. The trace and the
    /// `AppDelegate.shared`/workspace-id binding are irreducibly app-coupled and
    /// order-sensitive, so this whole tail stays on the host; the coordinator owns
    /// only the destination-to-`(targetPane, targetIndex, splitTarget)`
    /// decomposition, which it has already performed and passes here alongside the
    /// original `sourcePaneId`/`destination` the begin trace formats.
    func moveExternalTab(
        tabId: UUID,
        sourcePaneId: PaneID,
        destination: BonsplitController.ExternalTabDropRequest.Destination,
        targetPane: PaneID,
        targetIndex: Int?,
        splitTarget: (orientation: SplitOrientation, insertFirst: Bool)?
    ) -> Bool
}
