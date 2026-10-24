import Foundation

/// Where a create pressed on a pane goes now (``DaemonStore/createTarget(for:)``).
enum CreateTarget: Equatable {
    /// The daemon's pane to name.
    case pane(PaneID)
    /// A stand-in whose create (this transaction) is still in flight and has no daemon pane yet: wait.
    case pending(ClientTransactionID)
    /// Nothing to name: an unknown stand-in.
    case gone
}
