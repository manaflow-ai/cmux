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
}
