#if canImport(IrohLib)
import Foundation
import IrohLib

/// The Ed25519 key behind an Iroh EndpointID, derived and used through the
/// same IrohLib key code the endpoint itself runs.
struct CmxIrohEndpointSigningKey: Sendable {
    private let key: SecretKey

    /// - Throws: IrohLib's error when `secretKeyBytes` is not a 32-byte seed.
    init(secretKeyBytes: Data) throws {
        key = try SecretKey.fromBytes(bytes: secretKeyBytes)
    }

    /// The 32-byte public key, which is the EndpointID.
    var publicKeyBytes: Data {
        key.public().toBytes()
    }

    /// The 64-byte Ed25519 signature of `message`.
    func signature(for message: Data) throws -> Data {
        key.sign(message: message).toBytes()
    }
}
#endif
