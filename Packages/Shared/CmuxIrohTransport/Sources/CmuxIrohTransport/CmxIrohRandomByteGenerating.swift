public import Foundation

/// Injectable cryptographic randomness boundary for one-use invitation proofs.
public protocol CmxIrohRandomByteGenerating: Sendable {
    func randomBytes(count: Int) throws -> Data
}

/// The system's cryptographic randomness: `SecRandomCopyBytes` where
/// Security.framework exists, `getrandom(2)` on Linux. One interface with a
/// source file per OS, as Chromium's `base/rand_util*.cc`.
public struct CmxIrohSystemRandomByteGenerator: CmxIrohRandomByteGenerating {
    public init() {}

    public func randomBytes(count: Int) throws -> Data {
        guard count > 0, let bytes = Self.systemRandomBytes(count: count) else {
            throw CmxIrohOfflinePairingSessionError.randomnessUnavailable
        }
        return bytes
    }
}
