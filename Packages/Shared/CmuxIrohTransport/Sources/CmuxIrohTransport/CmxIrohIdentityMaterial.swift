public import CMUXMobileCore
import Foundation
import IrohLib

/// Stable Iroh identity material for one signed-in account and app instance.
public struct CmxIrohIdentityMaterial: Equatable, Sendable {
    /// The device-local Ed25519 secret that determines the EndpointID.
    public let secretKey: CmxIrohSecretKey

    /// Monotonic generation changed only when this identity rotates.
    public let generation: Int

    /// Creates validated identity material.
    ///
    /// - Parameters:
    ///   - secretKey: The 32-byte Iroh secret.
    ///   - generation: A positive PostgreSQL-compatible identity generation.
    /// - Throws: ``CmxIrohIdentityRepositoryError/invalidGeneration`` for an
    ///   out-of-range generation.
    public init(secretKey: CmxIrohSecretKey, generation: Int) throws {
        guard (1...Int(Int32.max)).contains(generation) else {
            throw CmxIrohIdentityRepositoryError.invalidGeneration
        }
        self.secretKey = secretKey
        self.generation = generation
    }

    /// The peer identity this material's secret derives, via the same
    /// IrohLib key derivation the endpoint itself uses. Lives here (not in
    /// the app target) because this package owns the IrohLib dependency;
    /// app-target code importing IrohLib directly is not linked against it.
    public var peerIdentity: CmxIrohPeerIdentity? {
        guard let endpoint = try? SecretKey.fromBytes(bytes: secretKey.bytes).public()
        else { return nil }
        let endpointID = endpoint.toBytes()
            .map { String(format: "%02x", $0) }
            .joined()
        return try? CmxIrohPeerIdentity(endpointID: endpointID)
    }
}
