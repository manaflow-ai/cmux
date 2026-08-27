public import Foundation

/// A validated 32-byte Ed25519 secret used to preserve an Iroh EndpointID.
public struct CmxIrohSecretKey: Equatable, Sendable {
    /// The raw secret bytes supplied only to the endpoint factory.
    public let bytes: Data

    /// Creates a validated endpoint secret.
    ///
    /// - Parameter bytes: Exactly 32 random bytes from device-local Keychain storage.
    /// - Throws: ``CmxIrohSecretKeyError/invalidByteCount(_:)`` for any other size.
    public init(bytes: Data) throws {
        guard bytes.count == 32 else {
            throw CmxIrohSecretKeyError.invalidByteCount(bytes.count)
        }
        self.bytes = bytes
    }
}
