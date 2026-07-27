public import Foundation

/// The outcome of the v1 `new_pane` split.
public enum ControlSidebarPaneSplitResolution: Sendable, Equatable {
    /// The pane was created.
    case created(UUID)
    /// The split was routed to the remote tmux mirror backing the workspace;
    /// the pane arrives asynchronously via `%layout-change` (no local id yet).
    case routedToRemote
    /// A left/up split aimed at a mirror workspace — the routed tmux
    /// `split-window` cannot insert before the target pane, so the request is
    /// rejected before the remote session is mutated.
    case mirrorInsertFirstRejected
    /// Creation failed.
    case failed
}
