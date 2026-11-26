public import Foundation

/// The outcome of `pane.last`, preserving the legacy body's distinct failures
/// and the focused alternate-pane identity it echoes back.
public enum ControlPaneLastResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// A TabManager resolved but no workspace did (legacy `not_found` /
    /// "Workspace not found", `data: nil`).
    case workspaceNotFound
    /// The workspace had no focused pane (legacy `not_found` / "No focused
    /// pane", `data: nil`).
    case noFocusedPane
    /// There was no pane other than the focused one (legacy `not_found` / "No
    /// alternate pane available", `data: nil`).
    case noAlternatePane
    /// The alternate pane was focused. Carries the echoed identity (window and
    /// selected surface may be absent; workspace and pane are present).
    case focused(windowID: UUID?, workspaceID: UUID, paneID: UUID, selectedSurfaceID: UUID?)
}
