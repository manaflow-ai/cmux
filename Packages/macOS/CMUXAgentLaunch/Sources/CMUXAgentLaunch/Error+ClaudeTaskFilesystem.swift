import Darwin
import Foundation

extension Error {
    /// Whether a filesystem operation failed because its target disappeared.
    var isClaudeTaskFilesystemItemMissing: Bool {
        let nsError = self as NSError
        let candidates = [
            nsError,
            nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
        ].compactMap { $0 }
        return candidates.contains { candidate in
            if candidate.domain == NSCocoaErrorDomain {
                return candidate.code == NSFileNoSuchFileError
                    || candidate.code == NSFileReadNoSuchFileError
            }
            return candidate.domain == NSPOSIXErrorDomain
                && candidate.code == Int(ENOENT)
        }
    }
}
