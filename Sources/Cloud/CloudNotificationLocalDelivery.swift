import Foundation

/// What became of a row handed to the local notification store.
enum CloudNotificationDeliveryOutcome: Equatable, Sendable {
    /// A local record exists; the row is consumed.
    case delivered
    /// Nothing here could take the row yet (no store, a placement that
    /// vanished between resolution and delivery); the next fold retries it.
    case declined
    /// This Mac will never show the row (an admission drop, a muted
    /// workspace): it is consumed and acknowledged as read at once, so no
    /// indicator anywhere waits for a dismissal that cannot happen.
    case suppressed
}

/// Turns one of a machine's notification rows into a local notification
/// record on the target the placement resolver chose. Owned by the machine's
/// provider; everything it reads arrives through closures so tests drive it
/// against the real store without a link.
@MainActor
struct CloudNotificationLocalDelivery {
    let machineID: String
    var store: @MainActor () -> TerminalNotificationStore?
    /// The hub's admission gate, shared across every live machine.
    var admit: @MainActor (CloudVMNotificationRow) -> CloudMachineNotificationGate.Decision
    var machineName: @MainActor () -> String
    /// The process title of a terminal from the accepted graph, for the
    /// subtitle when the producer gave none.
    var terminalTitle: @MainActor (_ terminalID: String) -> String?

    func deliver(_ row: CloudVMNotificationRow, to target: CloudNotificationDeliveryTarget) -> CloudNotificationDeliveryOutcome {
        guard let store = store() else { return .declined }
        // Dropped rows remain consumed by the sync so subsequent catalog folds
        // cannot replay a flood.
        guard admit(row) == .allowed else { return .delivered }
        let terminalTitle = row.terminalID.flatMap(terminalTitle) ?? ""
        let machineName = machineName()
        let subtitle: String
        if let explicit = row.subtitle {
            // The producer's own subtitle wins, as `cmux notify --subtitle` does locally.
            subtitle = explicit
        } else if terminalTitle.isEmpty {
            subtitle = machineName
        } else {
            subtitle = String(
                format: String(localized: "cloudNotification.subtitle.machine", defaultValue: "%@ on %@"),
                terminalTitle,
                machineName
            )
        }
        let recorded = store.addNotification(
            tabId: target.workspaceID,
            surfaceId: target.panelID,
            title: row.title,
            subtitle: subtitle,
            body: row.body,
            retargetsToLiveSurfaceOwner: target.panelID != nil,
            correlationKey: CloudNotificationCorrelation.key(machineID: machineID, notificationID: row.id),
            origin: .cloudVM(machineID: machineID)
        ) != nil
        return recorded ? .delivered : .declined
    }
}
