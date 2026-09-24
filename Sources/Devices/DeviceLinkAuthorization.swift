import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// A Mac the person paired in Settings › Computers, as the directory lists it:
/// local-first, so it is listed and dialable even when the registry and the
/// presence stream are unavailable, with the saved routes as dial candidates.
struct DevicePairedDevice: Equatable, Sendable {
    let instance: SurfaceDeviceInstanceID
    let displayName: String
    /// The pairing's saved routes (published routes plus the granted Tailscale
    /// peers), in the host's priority order.
    let routes: [CmxAttachRoute]
    let lastSeenAt: Date?
}

/// The explicit-authorization seam between the Devices runtime and the pairing
/// store (Settings › Computers). Discovery (the registry, presence) proposes a
/// device's routes; only this source can authorize dialing one, with the
/// device-bound grant it recorded when the person paired that Mac. Nothing in
/// the runtime derives an authorization from a discovered route.
/// `HiveComputersService` is the production source.
@MainActor
protocol DeviceLinkAuthorizationSource: AnyObject {
    /// Every paired Mac, for the directory's local-first merge.
    var pairedDevices: [DevicePairedDevice] { get }
    /// The grant for dialing `route` to `instance`, or nil when the person has
    /// not paired that Mac (or paired it at another address).
    func authorization(for instance: SurfaceDeviceInstanceID, route: CmxAttachRoute) -> CmxLegacyTailscaleAuthorizationEvidence?
    /// Posted whenever a pairing or grant changes; the directory re-merges and
    /// every link re-evaluates on it, so a new pairing dials at once and an
    /// unpair drops the live link.
    var authorizationDidChangeNotification: Notification.Name { get }
}

extension HiveComputersService: DeviceLinkAuthorizationSource {
    var authorizationDidChangeNotification: Notification.Name { Self.didChangeNotification }

    var pairedDevices: [DevicePairedDevice] {
        pairedComputers.map { computer in
            var routes = computer.routes
            for legacy in computer.legacyTailscaleRoutes where !routes.contains(where: { $0.endpoint == legacy.endpoint }) {
                routes.append(legacy)
            }
            return DevicePairedDevice(
                instance: SurfaceDeviceInstanceID(deviceID: computer.deviceID, tag: computer.instanceTag),
                displayName: computer.displayName,
                routes: routes,
                lastSeenAt: computer.lastSeenAt
            )
        }
    }
}

/// The identity check every (re)connect performs before it subscribes: the
/// host's authenticated status must name exactly the device and app instance
/// the row dialed. The host includes those fields only for a caller that proved
/// same-account ownership, so an absent identity means the answering Mac is not
/// this account's; a different identity means the address now belongs to
/// another Mac. Neither is retried: only a new pairing changes it.
enum DeviceLinkHostIdentity {
    static func verify(statusResponse: Data, expected: SurfaceDeviceInstanceID) throws {
        let status: MobileHostStatusResponse
        do {
            status = try JSONDecoder().decode(MobileHostStatusResponse.self, from: statusResponse)
        } catch {
            throw DeviceLinkError.malformedResponse("mobile.host.status")
        }
        try verify(status: status, expected: expected)
    }

    static func verify(status: MobileHostStatusResponse, expected: SurfaceDeviceInstanceID) throws {
        guard let deviceID = status.macDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines), !deviceID.isEmpty,
              let tag = status.macInstanceTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
            throw DeviceLinkError.identityUnproven
        }
        guard SurfaceDeviceInstanceID(deviceID: deviceID, tag: tag) == expected else {
            throw DeviceLinkError.identityMismatch
        }
    }
}
