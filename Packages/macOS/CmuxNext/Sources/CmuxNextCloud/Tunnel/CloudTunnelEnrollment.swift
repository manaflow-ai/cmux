import Foundation

/// `POST /api/vm/tunnel` request and response. `clientConfig` is a wg-quick
/// file whose `PrivateKey` line is empty; ``WireGuardConfig`` completes it.
public struct CloudTunnelEnrollment: Sendable, Hashable, Decodable {
    public struct Network: Sendable, Hashable, Decodable {
        public var cidr: String?
        public var cidrV6: String?
    }

    public struct Request: Sendable, Hashable {
        public var clientPublicKey: String
        public var deviceID: String
        public var deviceName: String
        public var osVersion: String
        public var architecture: String
        public var appVersion: String

        var body: [String: any Sendable] {
            [
                "clientPublicKey": clientPublicKey,
                // One stable id per installation serves as both the device id
                // and the fingerprint the server keys the peer by.
                "deviceFingerprint": deviceID,
                "deviceId": deviceID,
                "tunnelPurpose": "terminal",
                "deviceName": deviceName,
                "osVersion": osVersion,
                "architecture": architecture,
                "cmuxVersion": appVersion,
                "cmuxChannel": "next",
            ]
        }
    }

    public var tunnelId: String
    public var clientConfig: String
    public var routes: [String]
    public var network: Network?
    public var networks: [Network]?
}

/// Completes the server's wg-quick file with this Mac's private key and
/// every private network route (the old app's `completedConfig`).
public enum WireGuardConfig {
    public static func completed(_ enrollment: CloudTunnelEnrollment, privateKey: String) -> String {
        var routes: [String] = []
        for network in (enrollment.networks ?? []) + [enrollment.network].compactMap({ $0 }) {
            for cidr in [network.cidr, network.cidrV6].compactMap({ $0 }) where !routes.contains(cidr) { routes.append(cidr) }
        }
        for route in enrollment.routes where !routes.contains(route) { routes.append(route) }
        var lines = enrollment.clientConfig.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { key(of: $0) == "privatekey" }) {
            lines[index] = "PrivateKey = \(privateKey)"
        } else if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[interface]" }) {
            lines.insert("PrivateKey = \(privateKey)", at: index + 1)
        }
        if !routes.isEmpty {
            let allowed = "AllowedIPs = \(routes.joined(separator: ", "))"
            if let index = lines.firstIndex(where: { key(of: $0) == "allowedips" }) {
                lines[index] = allowed
            } else if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[peer]" }) {
                lines.insert(allowed, at: index + 1)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func key(of line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        return line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
    }
}
