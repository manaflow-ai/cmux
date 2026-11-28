public import CMUXMobileCore
public import Foundation

extension MobileIrxHost {
    public enum TicketFailure: Error, CustomStringConvertible {
        /// The endpoint is not listening on a relay yet (the launcher retries on this text).
        case routesUnavailable

        public var description: String { "Mobile host routes are not available yet" }
    }

    /// A Mac-scoped attach ticket for `target` (MobileAttachTicket), once
    /// the endpoint listens on a relay and the v2 device is provisioned.
    public func attachTicket(ttl: TimeInterval, target: MobileAttachTicket.Target,
                             scheme: CmxPairingURLScheme?) throws -> MobileAttachTicket.Payload {
        guard case .listening = phase, let macDeviceID, let identity else { throw TicketFailure.routesUnavailable }
        let host = MobileAttachTicket.HostIdentity(
            macDeviceID: macDeviceID, endpointID: identity.endpointIDHex, displayName: configuration.displayName,
            userID: auth.userID, appVersion: configuration.appVersion, appBuild: configuration.appBuild)
        return try MobileAttachTicket.make(host, ttl: ttl, target: target, scheme: scheme)
    }
}
