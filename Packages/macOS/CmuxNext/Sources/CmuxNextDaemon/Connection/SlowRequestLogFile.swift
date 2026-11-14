import CmuxNextCompat
import Darwin
import Foundation

/// The file of the app's slow request log (``SlowRequestLog``): `slow-requests-app.jsonl` and one
/// rotated copy `slow-requests-app.jsonl.1` in `directory`, each at most
/// ``SlowRequestLog/maxFileBytes``, mode 0600. Used only on the log's writer queue.
///
/// A line that would pass the limit first renames the file to `.1` (the older `.1` goes), so the two
/// files never hold more than twice the limit. When the rename fails, the file is emptied instead, so
/// it holds the newest records and still obeys the limit. No `fsync`: a record is a diagnostic, not user data.
struct SlowRequestLogFile {
    let directory: URL

    /// Appends `line` and a newline. A folder that does not exist, or a file that cannot be opened,
    /// gets nothing (the folder is the daemon's: it is never created here).
    func append(_ line: String) {
        let path = directory.appendingPathComponent(SlowRequestLog.fileName).path
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        var descriptor = Self.open(path)
        guard descriptor >= 0 else { return }
        var info = stat()
        if fstat(descriptor, &info) == 0, Int(truncatingIfNeeded: info.st_size) + bytes.count > SlowRequestLog.maxFileBytes {
            if rename(path, path + ".1") == 0 {
                close(descriptor)
                descriptor = Self.open(path)
                guard descriptor >= 0 else { return }
            } else if ftruncate(descriptor, 0) != 0 {
                // No rotated copy can be made (its name is a folder, the folder is read-only) and the file
                // cannot be emptied: the record goes, the file does not grow.
                close(descriptor)
                return
            }
        }
        // One write of less than a page to an O_APPEND descriptor: the line is whole or absent.
        _ = bytes.withUnsafeBytes { blockingWrite(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
    }

    /// Opens the file for append, creating it with mode 0600 (an older file gets that mode too).
    private static func open(_ path: String) -> Int32 {
        let descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if descriptor >= 0 { fchmod(descriptor, 0o600) }
        return descriptor
    }
}
