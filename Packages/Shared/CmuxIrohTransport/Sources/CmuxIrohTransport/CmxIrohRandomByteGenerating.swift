public import Foundation
#if canImport(Security)
import Security
#endif

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
        #if canImport(Security)
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw CmxIrohOfflinePairingSessionError.randomnessUnavailable
        }
        return bytes
        #else
        // Platforms without Security.framework: the system CSPRNG (getrandom on Linux).
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        #endif
    }
}
