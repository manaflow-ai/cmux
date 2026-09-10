import CMUXMobileCore
import Foundation

/// What the account's presence service currently says about a device.
enum DeviceDirectoryPresence: Equatable, Sendable {
    case online
    case offline
    /// No report: the stream is down, or the device is known only from its
    /// pairing. Presence is a label, never a gate, for a paired Mac.
    case unknown
}

/// One other Mac on the account, as the Devices directory knows it: the
/// pairing store's saved record (local-first), the registry's durable identity,
/// and live presence, merged. This is the value the provider registry turns
/// into a `SurfaceProvider` and the panel renders.
struct DeviceDirectoryRecord: Equatable, Sendable, Identifiable {
    var id: SurfaceDeviceInstanceID { instance }

    let instance: SurfaceDeviceInstanceID
    /// The device's own name (presence, then the pairing, then the registry).
    let deviceName: String
    let platform: String
    let bundleID: String?
    let presenceState: DeviceDirectoryPresence
    /// Whether the person paired this Mac in Settings › Computers. Only a
    /// paired Mac has a dial grant, and a paired Mac dials regardless of what
    /// presence says: saved routes must work when presence and the registry are
    /// unavailable.
    let isPaired: Bool
    /// Discovery history may retain an offline Mac after its live sources
    /// expire. A pairing-only entry has no such reason to survive unpairing.
    var wasDiscovered: Bool = false
    let lastSeenAt: Date?
    /// Dial candidates in the host's priority order: the pairing's saved routes
    /// first, then live presence routes while online, then the registry's.
    let routes: [CmxAttachRoute]
    let ownerUserID: String?
    let accountTrust: SurfaceDevicePresence.AccountTrust

    var isOnline: Bool { presenceState == .online }

    /// Tag-qualified name for rows and progress labels.
    var displayName: String {
        CloudTreeDeviceRow.displayName(baseName: deviceName, instance: instance)
    }

    var presence: SurfaceDevicePresence {
        let state: SurfaceDevicePresence.State
        switch presenceState {
        case .online: state = .online
        case .offline: state = .offline
        case .unknown: state = .unknown
        }
        return SurfaceDevicePresence(
            state: state,
            lastSeenAt: lastSeenAt,
            tag: instance.tag,
            bundleID: bundleID,
            accountTrust: accountTrust
        )
    }

    /// Whether the link may dial now: routed, this account's, and either paired
    /// (presence never suppresses a saved link) or reported online. The host
    /// rejects any other account, and dialing it would hand our bearer token to
    /// a peer we cannot attribute.
    var isDialable: Bool {
        !routes.isEmpty && accountTrust == .sameAccount && (isPaired || isOnline)
    }
}
