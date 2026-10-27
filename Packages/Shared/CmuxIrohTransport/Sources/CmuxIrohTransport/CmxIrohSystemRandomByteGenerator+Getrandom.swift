#if !canImport(Security)
import Foundation

extension CmxIrohSystemRandomByteGenerator {
    /// `count` bytes from `SystemRandomNumberGenerator`, which reads
    /// `getrandom(2)` on Linux (the source of `base::RandBytes` in Chromium's
    /// `base/rand_util_posix.cc`) and traps rather than return weak bytes.
    static func systemRandomBytes(count: Int) -> Data? {
        var generator = SystemRandomNumberGenerator()
        var bytes = Data(capacity: max(count, 0))
        for _ in 0..<max(count, 0) {
            bytes.append(UInt8.random(in: .min ... .max, using: &generator))
        }
        return bytes
    }
}
#endif
