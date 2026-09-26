public import Foundation

/// Produces the wg-quick text the in-process tunnel parses.
///
/// The control plane returns a complete config with `PrivateKey` blank. This
/// fills the key and pins `PersistentKeepalive` so carrier NAT keeps the
/// mapping alive while the section is open. The text stays in memory.
public struct WireGuardQuickConfig: Sendable, Equatable {
    /// Failures while completing a server config.
    public enum Failure: Error, Equatable, Sendable {
        /// The server text has no `[Interface]` section.
        case missingInterfaceSection
        /// The server text has no `[Peer]` section.
        case missingPeerSection
    }

    /// The keepalive every phone tunnel uses, in seconds.
    public static let persistentKeepaliveSeconds = 25

    /// The completed wg-quick text.
    public var text: String

    /// Completes the server-issued config with the device's private key.
    /// - Parameters:
    ///   - serverConfig: The `clientConfig` from enrollment.
    ///   - privateKey: Base64 private key from the Keychain.
    ///   - persistentKeepalive: Keepalive to pin; default 25 s.
    public init(
        completing serverConfig: String,
        privateKey: String,
        persistentKeepalive: Int = persistentKeepaliveSeconds
    ) throws {
        var lines = serverConfig.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func sectionIndex(_ name: String) -> Int? {
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[\(name)]" }
        }
        guard let interfaceIndex = sectionIndex("interface") else { throw Failure.missingInterfaceSection }
        guard let peerIndex = sectionIndex("peer") else { throw Failure.missingPeerSection }

        if let keyIndex = lines.firstIndex(where: { Self.key(of: $0) == "privatekey" }) {
            lines[keyIndex] = "PrivateKey = \(privateKey)"
        } else {
            lines.insert("PrivateKey = \(privateKey)", at: interfaceIndex + 1)
        }

        let keepaliveLine = "PersistentKeepalive = \(persistentKeepalive)"
        if let keepaliveIndex = lines.firstIndex(where: { Self.key(of: $0) == "persistentkeepalive" }) {
            lines[keepaliveIndex] = keepaliveLine
        } else {
            let peerAfterKeyInsert = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[peer]" } ?? peerIndex
            lines.insert(keepaliveLine, at: peerAfterKeyInsert + 1)
        }
        text = lines.joined(separator: "\n")
    }

    /// Builds a config from enrollment fields when the server sends no text.
    /// - Parameters:
    ///   - enrollment: The enrollment record (addresses, routes, endpoint, server key).
    ///   - privateKey: Base64 private key from the Keychain.
    ///   - mtu: Interface MTU; Freestyle issues 1200.
    ///   - persistentKeepalive: Keepalive to pin; default 25 s.
    public init(
        enrollment: CloudTunnelEnrollment,
        privateKey: String,
        mtu: Int = 1200,
        persistentKeepalive: Int = persistentKeepaliveSeconds
    ) {
        var lines = ["[Interface]", "PrivateKey = \(privateKey)"]
        if let v4 = enrollment.addressV4 { lines.append("Address = \(Self.hostAddress(v4, bits: 32))") }
        if let v6 = enrollment.addressV6 { lines.append("Address = \(Self.hostAddress(v6, bits: 128))") }
        lines.append("MTU = \(mtu)")
        lines.append("")
        lines.append("[Peer]")
        lines.append("PublicKey = \(enrollment.serverPublicKey)")
        lines.append("AllowedIPs = \(enrollment.routes.joined(separator: ", "))")
        if let host = enrollment.endpointHost {
            let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            lines.append("Endpoint = \(bracketed):\(enrollment.endpointPort)")
        }
        lines.append("PersistentKeepalive = \(persistentKeepalive)")
        text = lines.joined(separator: "\n") + "\n"
    }

    /// The config for an enrollment: the server text when present, otherwise
    /// one assembled from fields.
    public static func make(enrollment: CloudTunnelEnrollment, privateKey: String) throws -> WireGuardQuickConfig {
        if !enrollment.clientConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try WireGuardQuickConfig(completing: enrollment.clientConfig, privateKey: privateKey)
        }
        return WireGuardQuickConfig(enrollment: enrollment, privateKey: privateKey)
    }

    private static func key(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        return trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func hostAddress(_ address: String, bits: Int) -> String {
        address.contains("/") ? address : "\(address)/\(bits)"
    }
}
