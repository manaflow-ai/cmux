import CryptoKit
public import CMUXMobileCore
import Foundation

/// Derives account-private local profile IDs without disclosing interface names.
public struct CmxIrohLANNetworkProfileGenerator: Sendable {
    private let keyBytes: [UInt8]
    private let rendezvousGeneration: Int

    public init(rendezvous: CmxIrohLANRendezvous) throws {
        let padding = String(repeating: "=", count: (4 - rendezvous.key.count % 4) % 4)
        let standard = rendezvous.key
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: standard), data.count == 32 else {
            throw CmxIrohLANRendezvousAliasError.invalidKey
        }
        keyBytes = Array(data)
        rendezvousGeneration = rendezvous.generation
    }

    public func profile(
        interfaceIndex: UInt32,
        pathGeneration: UInt64
    ) throws -> CmxIrohNetworkProfileKey {
        guard interfaceIndex != 0 else { throw CmxIrohLANDiscoveryError.invalidInterface }
        let transcript = Data(
            "cmux/iroh/lan-network-profile/v1\0\(rendezvousGeneration)\0\(pathGeneration)\0\(interfaceIndex)".utf8
        )
        let key = SymmetricKey(data: keyBytes)
        let digest = HMAC<SHA256>.authenticationCode(for: transcript, using: key)
            .map { String(format: "%02x", $0) }
            .joined()
        return try CmxIrohNetworkProfileKey(source: .lan, profileID: digest)
    }
}
