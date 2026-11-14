internal import Foundation

extension Data {
    /// Whether the bytes contain an ESC, found with memchr. The escape filters run
    /// this on every mirrored output chunk, and a flood of output is hundreds of
    /// megabytes; `contains(_:)` walks the bytes one iterator step at a time.
    var containsEscapeByte: Bool {
        withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return false }
            return memchr(base, 0x1b, raw.count) != nil
        }
    }
}
