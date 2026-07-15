import Foundation

/// Resolves a `*.ts.net` input against an authenticated `tailscale status --json`
/// snapshot and returns one deterministic numeric transport target.
///
/// This parser does not perform DNS. It trusts only the local Tailscale daemon's
/// control-plane peer map, requires one exact record, validates every address in
/// that record, and then prefers IPv4 over IPv6. The caller persists the numeric
/// result so iOS never has to trust or re-resolve the DNS name.
public struct CmxTailscaleStatusPeerResolver: Sendable {
    /// Maximum accepted status size, bounding local command output parsing.
    public static let maximumStatusBytes = 8 * 1024 * 1024
    /// Maximum peer records inspected from one status snapshot.
    public static let maximumPeerRecords = 16_384

    /// Creates a stateless status resolver.
    public init() {}

    /// Finds one exact peer record for a MagicDNS name.
    /// - Parameters:
    ///   - magicDNSName: A fully qualified `*.ts.net` name, with an optional trailing dot.
    ///   - statusJSON: Authenticated local output from `tailscale status --json`.
    ///   - allowLocalDevice: Whether a matching `Self` record may be returned.
    /// - Returns: The exact peer record and deterministic numeric target.
    /// - Throws: ``CmxTailscaleStatusPeerResolutionError`` when the name or status is unsafe.
    public func resolve(
        magicDNSName: String,
        statusJSON: Data,
        allowLocalDevice: Bool = false
    ) throws -> CmxTailscalePeerRecord {
        guard let requestedName = normalizedMagicDNSName(magicDNSName) else {
            throw CmxTailscaleStatusPeerResolutionError.invalidMagicDNSName
        }
        guard !statusJSON.isEmpty,
              statusJSON.count <= Self.maximumStatusBytes,
              let root = try? JSONSerialization.jsonObject(with: statusJSON) as? [String: Any] else {
            throw CmxTailscaleStatusPeerResolutionError.malformedStatus
        }
        guard root["BackendState"] as? String == "Running" else {
            throw CmxTailscaleStatusPeerResolutionError.statusNotRunning
        }

        var candidates: [(object: [String: Any], isLocalDevice: Bool)] = []
        if let local = root["Self"] as? [String: Any] {
            candidates.append((local, true))
        }
        if let peers = root["Peer"] as? [String: Any] {
            guard peers.count <= Self.maximumPeerRecords else {
                throw CmxTailscaleStatusPeerResolutionError.malformedStatus
            }
            candidates.append(contentsOf: peers.values.compactMap { value in
                guard let object = value as? [String: Any] else { return nil }
                return (object, false)
            })
        } else if root["Peer"] != nil, !(root["Peer"] is NSNull) {
            throw CmxTailscaleStatusPeerResolutionError.malformedStatus
        }

        let matches = candidates.filter { candidate in
            guard let dnsName = candidate.object["DNSName"] as? String else { return false }
            return normalizedDNSName(dnsName) == requestedName
        }
        guard !matches.isEmpty else {
            throw CmxTailscaleStatusPeerResolutionError.peerNotFound
        }
        guard matches.count == 1, let match = matches.first else {
            throw CmxTailscaleStatusPeerResolutionError.ambiguousPeer
        }
        guard allowLocalDevice || !match.isLocalDevice else {
            throw CmxTailscaleStatusPeerResolutionError.localDeviceNotAllowed
        }
        guard let rawAddresses = match.object["TailscaleIPs"] as? [Any],
              !rawAddresses.isEmpty else {
            throw CmxTailscaleStatusPeerResolutionError.missingPeerAddresses
        }

        var addresses = Set<CmxTailscalePeerAddress>()
        for rawAddress in rawAddresses {
            guard let value = rawAddress as? String,
                  let address = CmxTailscalePeerAddress(value) else {
                throw CmxTailscaleStatusPeerResolutionError.invalidPeerAddress
            }
            addresses.insert(address)
        }
        guard !addresses.isEmpty else {
            throw CmxTailscaleStatusPeerResolutionError.missingPeerAddresses
        }
        let orderedAddresses = addresses.sorted(by: Self.addressPrecedes)
        guard let preferredAddress = orderedAddresses.first else {
            throw CmxTailscaleStatusPeerResolutionError.missingPeerAddresses
        }

        return CmxTailscalePeerRecord(
            stableID: (match.object["ID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            dnsName: requestedName,
            addresses: orderedAddresses,
            preferredAddress: preferredAddress,
            isLocalDevice: match.isLocalDevice
        )
    }

    private func normalizedMagicDNSName(_ rawName: String) -> String? {
        guard let name = normalizedDNSName(rawName), name.hasSuffix(".ts.net") else {
            return nil
        }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, name.count <= 253 else { return nil }
        for label in labels {
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-",
                  label.utf8.allSatisfy({ byte in
                      (byte >= 0x61 && byte <= 0x7A) ||
                          (byte >= 0x30 && byte <= 0x39) ||
                          byte == 0x2D
                  }) else {
                return nil
            }
        }
        return name
    }

    private func normalizedDNSName(_ rawName: String) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
        guard !name.isEmpty, !name.hasSuffix(".") else { return nil }
        return name
    }

    private static func addressPrecedes(
        _ lhs: CmxTailscalePeerAddress,
        _ rhs: CmxTailscalePeerAddress
    ) -> Bool {
        if lhs.family != rhs.family {
            return lhs.family == .ipv4
        }
        return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}
