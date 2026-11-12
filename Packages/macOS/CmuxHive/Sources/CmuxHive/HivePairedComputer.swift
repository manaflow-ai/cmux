import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

/// An account-scoped Mac app instance with locally persisted connection authority.
public struct HivePairedComputer: Equatable, Sendable, Identifiable {
    /// The physical Mac's canonical device identifier.
    public let deviceID: String
    /// The exact authenticated build tag, including `default` for the stable app.
    public let instanceTag: String
    /// The locally customized or authenticated host name.
    public let displayName: String
    /// Routes retained for this exact pairing; discovery alone cannot authorize them.
    public let routes: [CmxAttachRoute]
    /// Device-local endpoint grants recorded after an explicit pairing handshake.
    public let legacyTailscaleRoutes: [CmxAttachRoute]
    /// The last successful local pairing update, not an online-presence assertion.
    public let lastSeenAt: Date

    /// The shared device-and-tag identity used by the paired-device store.
    public var id: String { CmxMacAppInstanceIdentity(macDeviceID: deviceID, instanceTag: instanceTag).id }

    init?(_ record: MobilePairedMac) {
        guard let instanceTag = record.instanceTag, !instanceTag.isEmpty else { return nil }
        guard !(record.legacyTailscaleRoutes ?? []).isEmpty || record.routes.contains(where: {
            $0.kind == .debugLoopback && CmxLoopbackHost().matches($0)
        }) else { return nil }
        deviceID = cmxCanonicalDeviceID(record.macDeviceID)
        self.instanceTag = instanceTag
        displayName = record.resolvedName
        routes = record.routes
        legacyTailscaleRoutes = record.legacyTailscaleRoutes ?? []
        lastSeenAt = record.lastSeenAt
    }

    /// Resolves authority only for an exact locally granted device, numeric IP, and port.
    public func authorization(for route: CmxAttachRoute) -> CmxLegacyTailscaleAuthorizationEvidence? {
        guard route.kind == .tailscale, case let .hostPort(host, port) = route.endpoint else { return nil }
        return legacyTailscaleRoutes.lazy.compactMap { stored -> CmxLegacyTailscaleAuthorizationEvidence? in
            guard stored.kind == .tailscale, case let .hostPort(storedHost, storedPort) = stored.endpoint,
                  let evidence = try? CmxLegacyTailscaleAuthorizationEvidence(
                    macDeviceID: deviceID, host: storedHost, port: storedPort
                  ), evidence.authorizes(macDeviceID: deviceID, host: host, port: port) else { return nil }
            return evidence
        }.first
    }
}
