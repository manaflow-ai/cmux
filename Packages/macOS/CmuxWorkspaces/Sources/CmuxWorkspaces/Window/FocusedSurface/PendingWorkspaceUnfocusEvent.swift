public import Foundation

/// A decision the ``FocusedSurfaceModel`` made about the deferred
/// previous-workspace unfocus, handed to the window host so it can emit the
/// legacy DEBUG trace line.
///
/// The model carries no logging of its own: the legacy
/// `cmuxDebugLog("ws.unfocus.…")` lines depended on the per-window
/// `TabManager` DEBUG workspace-switch snapshot (`id`/`dt`) and the
/// `debugShortWorkspaceId`/`debugMsText` formatters, all app-target. Rather
/// than drag that DEBUG tracing infrastructure into the package, the model
/// reports the structured decision and the host (in `#if DEBUG`) formats the
/// byte-identical line. In release builds the host method is a no-op, exactly
/// as the original `#if DEBUG`-guarded `cmuxDebugLog` calls were.
public enum PendingWorkspaceUnfocusEvent: Sendable {
    /// A pending target was stored to be flushed after handoff
    /// (legacy `ws.unfocus.defer`).
    case deferred(workspaceId: UUID, panelId: UUID)
    /// The pending target was flushed (unfocused) because it was replaced by a
    /// newer one (legacy `ws.unfocus.flush … reason=replaced`).
    case flushedOnReplace(workspaceId: UUID, panelId: UUID)
    /// A replacement target was dropped without unfocusing because it is the
    /// currently selected workspace (legacy
    /// `ws.unfocus.drop … reason=replaced_selected`).
    case droppedOnReplaceSelected(workspaceId: UUID, panelId: UUID)
    /// A pending completion was dropped because the tab became selected again
    /// before handoff (legacy `ws.unfocus.drop … reason=selected_again`).
    case droppedSelectedAgain(workspaceId: UUID, panelId: UUID)
    /// A pending target was completed (unfocused) on handoff
    /// (legacy `ws.unfocus.complete`).
    case completed(workspaceId: UUID, panelId: UUID, reason: String)
}
