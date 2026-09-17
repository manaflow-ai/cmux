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
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CmxIrohOfflinePairingSessionError.randomnessUnavailable
        }
        return bytes
    }
}
