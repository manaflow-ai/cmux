import CmuxMobileShellModel
import Foundation

/// Immutable per-computer snapshot for the Computers screen.
struct MacComputerSnapshot: Equatable, Identifiable {
    let deviceId: String
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
    /// The Mac-chosen mobile transport mode (`cmuxRelay`/`ownRelay`/`tailscale`)
    /// from its heartbeat, rendered as a read-only badge. `nil` when the host
    /// hasn't announced one (older build, or no presence yet).
    var transportMode: String?
    /// The reachable route the phone would dial.
    let routeDescription: String?
    /// Whether the stored iroh EndpointId no longer matches the advertised route.
    let identityMismatch: Bool
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

    var id: String { deviceId }
}
