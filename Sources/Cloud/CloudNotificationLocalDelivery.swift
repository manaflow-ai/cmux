import CmuxCloud
import CmuxNotifications
import Foundation

/// Turns one of a machine's notification rows into a local notification
/// record on the target the placement resolver chose. Owned by the machine's
/// provider; everything it reads arrives through closures so tests drive it
/// against the real store without a link.
@MainActor
struct CloudNotificationLocalDelivery {
    let machineID: String
    /// `.cloudVM` for a Cloud machine, `.deviceMac` for another Mac.
    var origin: TerminalNotificationOrigin
    var store: @MainActor () -> TerminalNotificationStore?
    /// The hub's admission gate, shared across every live machine.
    var admit: @MainActor (CloudVMNotificationRow) -> CloudMachineNotificationGate.Decision
    var machineName: @MainActor () -> String
    /// The process title of a terminal from the accepted graph, for the
    /// subtitle when the producer gave none.
    var terminalTitle: @MainActor (_ terminalID: String) -> String?

    func deliver(_ row: CloudVMNotificationRow, to target: CloudNotificationDeliveryTarget) -> CloudNotificationDeliveryOutcome {
        guard let store = store() else { return .declined }
        // Workspace mute is an admission decision of the person's own: the
        // row is read here rather than left as a dot no local dismissal can
        // reach. Decided before the gate so a muted row costs no budget.
        let admissionWorkspaceID = store.notificationMuteAdmissionTabID(
            claimedTabId: target.workspaceID,
            surfaceId: target.panelID,
            retargetsToLiveSurfaceOwner: target.panelID != nil
        )
        guard !store.isWorkspaceNotificationsMuted(forTabId: admissionWorkspaceID) else { return .suppressed }
        switch admit(row) {
        case .allowed:
            break
        case .duplicateID, .identicalContent:
            // A repeat of something this Mac already showed (or a row the
            // store declined on an earlier fold). Nothing will ever show it,
            // so it must not stay unread anywhere: read it now.
            return .suppressed
        case .machineRate, .fleetRate:
            // Over budget right now. The row keeps its dot and is retried on
            // the next fold, when the bucket has refilled; the burst is
            // spread out, not lost. Tokens are only taken by admitted rows,
            // so a retry never costs anything.
            return .declined
        }
        let terminalTitle = row.terminalID.flatMap(terminalTitle) ?? ""
        let machineName = machineName()
        // The producer's own subtitle replaces the terminal title, as
        // `cmux notify --subtitle` does locally, but the machine name stays.
        let subtitle = RemoteMachineNotificationSubtitle(
            format: String(localized: "cloudNotification.subtitle.machine", defaultValue: "%@ on %@")
        ).subtitle(explicit: row.subtitle, terminalTitle: terminalTitle, machineName: machineName)
        let recorded = store.addNotification(
            tabId: target.workspaceID,
            surfaceId: target.panelID,
            title: row.title,
            subtitle: subtitle,
            body: row.body,
            retargetsToLiveSurfaceOwner: target.panelID != nil,
            correlationKey: CloudNotificationCorrelation.key(machineID: machineID, notificationID: row.id),
            origin: origin
        ) != nil
        // Any other decline is transient (the pane's live owner vanished
        // between placement and delivery): the next fold re-resolves it. A
        // second attempt meets the gate's duplicate-id rule and is read.
        return recorded ? .delivered : .declined
    }
}
