import Bonsplit
import CmuxPanes
import CoreGraphics
import Foundation

/// `Workspace`'s conformance to the `CmuxPanes` ``SurfaceSplitWorkspaceHandle``
/// seam: the per-workspace surface-navigation, terminal-split-creation, and
/// split-operation operations the package ``SurfaceSplitCoordinator`` drives but
/// cannot own, because `Workspace` is an app-target god type owning the Bonsplit
/// split tree and the terminal `TerminalPanel` instances.
///
/// Most requirements are witnessed by the `Workspace` members they name directly:
/// `focusedPanelId`/`hasPanel` (already witnessed for ``BrowserOpenWorkspaceHandle``),
/// `surfaceIdFromPanelId`, `paneId(forPanelId:)`, `bonsplitController`, the four
/// `select*Surface` commands, `clearSplitZoom() -> Bool`, `moveFocus(direction:)`,
/// `toggleSplitZoom(panelId:)`, and `closePanel(_:force:) -> Bool`. None of those
/// need a wrapper here.
///
/// Only the two creation members need a wrapper, because they convert the
/// `Workspace`'s `TerminalPanel?` return to a `UUID?` at the boundary so the
/// package never sees the app-owned panel reference; they carry the
/// `surfaceSplit` prefix so a same-name-same-arity method differing only by
/// return type does not make the existing `Workspace` call sites ambiguous.
extension Workspace: SurfaceSplitWorkspaceHandle {
    func surfaceSplitNewTerminalSurfaceInFocusedPane(focus: Bool, initialInput: String?) -> UUID? {
        newTerminalSurfaceInFocusedPane(focus: focus, initialInput: initialInput)?.id
    }

    func surfaceSplitNewTerminalSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool,
        workingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        startupEnvironment: [String: String],
        initialDividerPosition: CGFloat?,
        remotePTYSessionID: String?
    ) -> UUID? {
        newTerminalSplit(
            from: panelId,
            orientation: orientation,
            insertFirst: insertFirst,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            startupEnvironment: startupEnvironment,
            initialDividerPosition: initialDividerPosition,
            remotePTYSessionID: remotePTYSessionID
        )?.id
    }
}
