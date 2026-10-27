public import Foundation
import Security

/// Injectable cryptographic randomness boundary for one-use invitation proofs.
public protocol CmxIrohRandomByteGenerating: Sendable {
    func randomBytes(count: Int) throws -> Data
}

/// Security.framework-backed production randomness.
public struct CmxIrohSystemRandomByteGenerator: CmxIrohRandomByteGenerating {
    public init() {}

    public func randomBytes(count: Int) throws -> Data {
        guard count > 0 else {
            throw CmxIrohOfflinePairingSessionError.randomnessUnavailable
        }
        let random = Self.secRandomBytes(count: count)
        guard random.status == errSecSuccess else {
            throw CmxIrohOfflinePairingSessionError.randomnessUnavailable
        }
        return random.bytes
    }

    /// `count` bytes from `SecRandomCopyBytes`, and its status (`errSecSuccess`
    /// or the failure the caller turns into its own typed error).
    static func secRandomBytes(count: Int) -> (bytes: Data, status: OSStatus) {
        var bytes = [UInt8](repeating: 0, count: max(count, 0))
        // SAFETY: SecRandomCopyBytes writes exactly the count it is given, bytes.count,
        // into the array's storage, which Swift keeps alive for this call only.
        let status = unsafe SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return (Data(bytes), status)
    }
}
