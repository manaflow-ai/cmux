import Foundation

/// Process-wide handle to the app-side Cloud tree service.
///
/// The sidebar and the pane drop path resolve the service through this one
/// accessor; the service fork assigns it at startup (composition root). When it
/// is `nil` — an older build or the service not yet wired — the panel falls back
/// to the CLI-launch verbs in `MachineRowActions`, and tree nodes are not shown.
enum CloudTreeServiceAccess {
    /// Assigned once by the composition root; read from the main actor only.
    @MainActor static var shared: (any CloudTreeServicing)?

    /// Posted by the service whenever a machine's tree changes (link state,
    /// workspaces, terminals). The panel re-reads the snapshot on receipt.
    static let didChangeNotification = Notification.Name("cmux.cloudTree.didChange")
}
