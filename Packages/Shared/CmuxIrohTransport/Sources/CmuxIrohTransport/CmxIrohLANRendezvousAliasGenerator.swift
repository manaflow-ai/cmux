import CryptoKit
public import Foundation

/// Derives short-lived, account-private Bonjour names for verified Iroh bindings.
///
/// A passive LAN observer sees only a rotating random-looking value. A signed-in
/// device with the current broker rendezvous key can map that value back to one
/// exact binding without advertising an EndpointID, account, device ID, build
/// tag, or display name over multicast DNS.
public struct CmxIrohLANRendezvousAliasGenerator: Sendable {
    /// Bonjour aliases rotate every five minutes.
    public static let rotationInterval: TimeInterval = 5 * 60

    private let keyBytes: [UInt8]
    private let generation: Int

    /// Creates a generator from authenticated broker rendezvous material.
    public init(rendezvous: CmxIrohLANRendezvous) throws {
        guard let keyData = Self.decodeBase64URL(rendezvous.key),
              keyData.count == 32 else {
            throw CmxIrohLANRendezvousAliasError.invalidKey
        }
        keyBytes = Array(keyData)
        generation = rendezvous.generation
    }

    /// Returns the current opaque alias for one exact broker binding.
    public func alias(
        for binding: CmxIrohBrokerBindingMetadata,
        at date: Date
    ) throws -> String {
        try alias(for: binding, epoch: Self.epoch(for: date))
    }

    /// Returns aliases accepted around the current clock boundary.
    ///
    /// The adjacent epochs tolerate ordinary device clock skew while bounding a
    /// captured advertisement's useful replay window.
    public func acceptedAliases(
        for binding: CmxIrohBrokerBindingMetadata,
        at date: Date
    ) throws -> Set<String> {
        let current = try Self.epoch(for: date)
        guard current > Int64.min, current < Int64.max else {
            throw CmxIrohLANRendezvousAliasError.invalidTimestamp
        }
        return try Set([
            alias(for: binding, epoch: current - 1),
            alias(for: binding, epoch: current),
            alias(for: binding, epoch: current + 1),
        ])
    }

    /// Resolves an opaque alias only when it identifies one verified binding.
    public func binding(
        matching alias: String,
        among candidates: [CmxIrohBrokerBindingMetadata],
        at date: Date
    ) throws -> CmxIrohBrokerBindingMetadata? {
        guard Self.isCanonicalAlias(alias),
              candidates.count <= CmxIrohDiscoveryResponse.maximumBindingCount else {
            return nil
        }
        var match: CmxIrohBrokerBindingMetadata?
        for candidate in candidates {
            guard try acceptedAliases(for: candidate, at: date).contains(alias) else {
                continue
            }
            guard match == nil else { return nil }
            match = candidate
        }
        return match
    }

    func alias(
        for binding: CmxIrohBrokerBindingMetadata,
        epoch: Int64
    ) throws -> String {
        guard binding.platform == .mac else {
            throw CmxIrohLANRendezvousAliasError.unsupportedPlatform
        }
        let transcript = Data(
            "cmux/iroh/lan-rendezvous-alias/v1\0\(generation)\0\(epoch)\0\(binding.bindingID)\0\(binding.deviceID)\0\(binding.appInstanceID)\0\(binding.tag)\0\(binding.platform.rawValue)\0\(binding.endpointID.endpointID)\0\(binding.identityGeneration)".utf8
        )
        let key = SymmetricKey(data: keyBytes)
        return HMAC<SHA256>.authenticationCode(for: transcript, using: key)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func epoch(for date: Date) throws -> Int64 {
        let value = date.timeIntervalSince1970
        guard value.isFinite, value >= 0,
              value <= TimeInterval(Int64.max) * rotationInterval else {
            throw CmxIrohLANRendezvousAliasError.invalidTimestamp
        }
        return Int64((value / rotationInterval).rounded(.down))
    }

    static func isCanonicalAlias(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        return Data(base64Encoded: standard)
    }
}
