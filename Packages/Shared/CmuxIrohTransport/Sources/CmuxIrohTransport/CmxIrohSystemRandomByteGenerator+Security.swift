#if canImport(Security)
import Foundation
import Security

extension CmxIrohSystemRandomByteGenerator {
    /// `count` bytes from `SecRandomCopyBytes`, or nil when it fails.
    static func systemRandomBytes(count: Int) -> Data? {
        let random = secRandomBytes(count: count)
        return random.status == errSecSuccess ? random.bytes : nil
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
#endif
