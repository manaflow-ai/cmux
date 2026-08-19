import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation

/// Immutable per-computer snapshot for the Connections screen.
///
/// One snapshot is one paired Mac app instance (device + build). The screen
/// shows it once per advertised connection method, so the visible row identity
/// is (device, build, route kind); ``MacComputerListSection`` derives those
/// per-kind rows from this snapshot's ``routes``.
struct MacComputerSnapshot: Equatable, Identifiable {
    let deviceId: String
    let instanceTag: String?
    let title: String
    let platform: String
    /// The Mac's distinct color index.
    var colorIndex: Int?
    /// User color override.
    var customColor: String?
    /// User icon override.
    var customIcon: String?
    /// The phone's live connection to this Mac.
    let connectionStatus: MobileMacConnectionStatus?
    /// Presence from the Durable Object presence worker.
    let presence: DeviceTreePresence?
    /// The host's build channel label from its heartbeat.
    var buildLabel: String?
    /// The reachable route the phone would dial. Rows inside a route-kind
    /// section override this with that kind's own endpoint.
    var routeDescription: String?
    /// Attach routes advertised by this pairing, priority order preserved.
    /// Drives the per-route-kind section membership.
    var routes: [CmxAttachRoute] = []
    /// When the Mac was last seen by the paired store.
    let lastSeenAt: Date
    /// How many aggregated workspaces this computer contributes.
    let workspaceCount: Int
    /// Stored paired-Mac ids represented by this visible row.
    let aliasIDs: [String]
    /// Whether a fresher row with the same computer name exists and this row is
    /// not online: almost always a stale pairing record from an older dev-build
    /// device id (pre-shared-device-id, cmux PR
    /// https://github.com/manaflow-ai/cmux/pull/6772), kept so the user can
    /// still reconnect or remove it. Labeled so several identically named
    /// entries stop looking interchangeable.
    var isOlderDuplicate: Bool = false

    var id: String {
        MobilePairedMac.pairingID(macDeviceID: deviceId, instanceTag: instanceTag)
    }
}
