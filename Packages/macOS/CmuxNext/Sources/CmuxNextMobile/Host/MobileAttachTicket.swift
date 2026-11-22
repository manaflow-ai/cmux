public import CMUXMobileCore
public import Foundation
import Security

/// Mac-scoped attach tickets (`mobile.attach_ticket.create`) for the iOS
/// dogfood launcher: which Mac to dial, as a pairing URL the target app
/// opens. The only route is this Mac's irx EndpointID; the phone finds the
/// relay through the v2 directory and the v2 same-account gate admits it
/// (the ticket's token authorizes nothing here). Built on the shared
/// CMUXMobileCore ticket and URL coders the phone decodes with.
public struct MobileAttachTicket {
    public init() {}
    /// Who consumes the URL. Each has one representation the phone accepts.
    public enum Target: String, Sendable {
        case simulatorInjection = "simulator_injection"
        case physicalDevice = "physical_device"

        public init?(wireValue: String) {
            self.init(rawValue: wireValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    /// This Mac as the phone sees it.
    public struct HostIdentity: Sendable, Equatable {
        public var macDeviceID: String
        public var endpointID: String
        public var displayName: String
        public var userID: String
        public var appVersion: String
        public var appBuild: String

        public init(macDeviceID: String, endpointID: String, displayName: String, userID: String, appVersion: String, appBuild: String) {
            self.macDeviceID = macDeviceID
            self.endpointID = endpointID
            self.displayName = displayName
            self.userID = userID
            self.appVersion = appVersion
            self.appBuild = appBuild
        }
    }

    public struct Payload: Sendable {
        public var ticket: CmxAttachTicket
        public var attachURL: String

        public var routes: [CmxAttachRoute] { ticket.routes }

        /// `{ticket, routes, attach_url, expires_at}`, the old app's reply shape.
        public func json(now: Date = Date()) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let disclosed = try ticket.authenticatedDisclosure(at: now)
            var object: [String: Any] = [
                "ticket": try JSONSerialization.jsonObject(with: encoder.encode(disclosed)),
                "routes": try JSONSerialization.jsonObject(with: encoder.encode(disclosed.routes)),
                "attach_url": attachURL,
            ]
            if let expiresAt = ticket.expiresAt { object["expires_at"] = ISO8601DateFormatter().string(from: expiresAt) }
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case noScheme
        case unencodable

        public var description: String {
            switch self {
            case .noScheme: "this Mac build has no iOS pairing URL scheme"
            case .unencodable: "the attach ticket cannot be represented as a pairing URL"
            }
        }
    }

    public static func make(_ host: HostIdentity, ttl: TimeInterval, target: Target, scheme: CmxPairingURLScheme?,
                            now: Date = Date()) throws -> Payload {
        guard let scheme else { throw Failure.noScheme }
        let route = try CmxAttachRoute(id: CmxAttachTransportKind.iroh.rawValue, kind: .iroh,
                                       endpoint: .peer(identity: try CmxIrohPeerIdentity(endpointID: host.endpointID), pathHints: []),
                                       priority: 0)
        let ticket = try CmxAttachTicket(
            workspaceID: "", terminalID: nil, macDeviceID: host.macDeviceID, macDisplayName: host.displayName,
            macUserID: host.userID, macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            macAppVersion: host.appVersion, macAppBuild: host.appBuild, routes: [route],
            expiresAt: now.addingTimeInterval(max(30, ttl)), authToken: randomToken())
        let url: String?
        switch target {
        case .physicalDevice:
            url = CmxPairingQRCode().encode(ticket, routeDisclosureMode: .irohIdentityOnly, pairingURLScheme: scheme)
        case .simulatorInjection:
            let data = try CmxAttachTicketCompactCoder().encode(ticket, routeDisclosureMode: .irohIdentityOnly)
            url = "\(scheme.rawValue)://attach?v=\(ticket.version)&payload=\(base64URL(data))"
        }
        guard let url else { throw Failure.unencodable }
        return Payload(ticket: ticket, attachURL: url)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return UUID().uuidString }
        return base64URL(Data(bytes))
    }
}
