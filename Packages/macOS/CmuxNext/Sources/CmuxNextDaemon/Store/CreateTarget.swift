import Foundation

/// Where a create pressed on a pane goes now (``DaemonStore/createTarget(for:)``).
enum CreateTarget: Equatable {
    /// The daemon's pane to name.
    case pane(PaneID)
    /// A stand-in whose create is still in flight and has no daemon pane yet: wait.
    case pending
    /// Nothing to name: an unknown stand-in.
    case gone
}
