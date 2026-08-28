import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation

/// Immutable per-Computer snapshot for the Computers screen.
///
/// One snapshot is one Computer — a paired Mac app instance (device + build).
/// Each Computer carries its own connection method, which decides the section
/// it appears under and the route its row and detail lead with.
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
    /// Whether the phone can control this Mac's keep-awake state right now
    /// (live connection + the Mac advertises the caffeine RPC).
    var supportsCaffeineControl: Bool = false
    /// This Mac's cmux-owned keep-awake state. `nil` while unknown, on Macs
    /// without the capability, and whenever the phone isn't connected.
    var caffeineEnabled: Bool?
    /// This Computer's effective connection method (its own stored choice,
    /// falling back to the app default). Decides the list section.
    var connectionMethod: MobileConnectionMethod?
    /// The route kind this Computer's method dials; the row endpoint and the
    /// detail view's leading route follow it.
    var routeKind: CmxAttachTransportKind?

    /// The pairing identity (device + build). Operations that are pairing
    /// scoped (visibility, forget, mutation spinners) key on this.
    var id: String {
        MobilePairedMac.pairingID(macDeviceID: deviceId, instanceTag: instanceTag)
    }

    /// The full connection identity (device + build + route kind) for
    /// per-row automation ids and navigation.
    var connectionRef: MacConnectionRef {
        MacConnectionRef(pairingID: id, routeKind: routeKind)
    }
}

/// One connection's identity: a pairing (device + build) reached over one
/// route kind. The navigation and automation identity of a Connections row.
struct MacConnectionRef: Hashable {
    let pairingID: String
    let routeKind: CmxAttachTransportKind?

    /// Stable string form for accessibility identifiers.
    var automationID: String {
        guard let routeKind else { return pairingID }
        return "\(pairingID)\u{1F}\(routeKind.rawValue)"
    }
}
