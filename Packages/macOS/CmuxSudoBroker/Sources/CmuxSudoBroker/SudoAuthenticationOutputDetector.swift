import Darwin
import Foundation

struct SudoAuthenticationOutputDetector: Sendable {
    /// The exact sudo password prompt monitored while Touch ID is active.
    static let passwordPrompt = "__CMUX_SUDO_PASSWORD_REQUIRED__"

    private let maximumBytes = 64 * 1_024

    func indicatesPasswordPrompt(at outputURL: URL) -> Bool {
        output(at: outputURL).contains(Self.passwordPrompt.lowercased())
    }

    private func output(at outputURL: URL) -> String {
        let descriptor = Darwin.open(outputURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return "" }
        defer { Darwin.close(descriptor) }

        let end = lseek(descriptor, 0, SEEK_END)
        guard end >= 0 else { return "" }
        let start = max(0, end - off_t(maximumBytes))
        guard lseek(descriptor, start, SEEK_SET) >= 0 else { return "" }

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
                return ""
            }
        }
        return String(decoding: bytes.prefix(offset), as: UTF8.self).lowercased()
    }
}
