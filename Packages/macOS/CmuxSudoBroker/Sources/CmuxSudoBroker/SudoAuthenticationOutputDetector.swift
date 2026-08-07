import Darwin
import Foundation

struct SudoAuthenticationOutputDetector: Sendable {
    private let maximumBytes = 64 * 1_024

    func indicatesAuthenticationFailure(at outputURL: URL) -> Bool {
        let descriptor = Darwin.open(outputURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        let end = lseek(descriptor, 0, SEEK_END)
        guard end >= 0 else { return false }
        let start = max(0, end - off_t(maximumBytes))
        guard lseek(descriptor, start, SEEK_SET) >= 0 else { return false }

        var bytes = [UInt8](repeating: 0, count: Int(end - start))
        var offset = 0
        while offset < bytes.count {
            let remainingCount = bytes.count - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    remainingCount
                )
            }
            if count > 0 {
                offset += count
            } else if count == 0 {
                break
            } else if errno != EINTR {
                return false
            }
        }
        let output = String(decoding: bytes.prefix(offset), as: UTF8.self).lowercased()
        return output.contains("password:")
            || output.contains("authentication failed")
            || output.contains("sorry, try again")
            || output.contains("a password is required")
    }
}
