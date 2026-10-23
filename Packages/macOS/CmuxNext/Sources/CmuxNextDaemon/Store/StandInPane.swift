import Foundation

/// A pending create's stand-in pane (``ProvisionalPane``), recorded when its intent enters the log:
/// what a later create pressed on it (Cmd-D, New Column, New Row, a new tab, a chat split) needs
/// to find the pane it must name at send time (``DaemonStore/daemonTarget(for:)``).
struct StandInPane: Equatable {
    /// The stand-in's public pane id: the daemon's pane takes it over under this id and a new handle.
    let paneID: String
    /// The pane the stand-in's create was made from. A create on a stand-in whose own create was
    /// cancelled or refused goes here instead, in the overlay and at send time.
    let anchor: PaneID
    /// The stand-in's own create.
    let transaction: ClientTransactionID
}
