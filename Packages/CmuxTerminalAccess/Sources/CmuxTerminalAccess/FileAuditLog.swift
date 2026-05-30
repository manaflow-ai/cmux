import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// File-backed ``AuditLog`` that appends one JSON object per line
/// (JSONL) to a single path.
///
/// Per Errata E2 this type is an `actor`: writes are serialized by
/// actor isolation, and ``record(_:)`` is `async` and non-throwing.
/// Backing-file errors are swallowed (the audit log is best-effort —
/// see ``AuditLog``).
///
/// Per spec, the log file's POSIX permissions are forced to **0600**
/// on every record call:
/// 1. The file is opened with `O_APPEND | O_CREAT | O_WRONLY` and
///    creation mode `0600`.
/// 2. After opening, `fchmod(2)` is applied to defend against a
///    pre-existing file with looser permissions (the Quality must_fix
///    on "FileAuditLog ignores existing file permissions on the
///    path").
///
/// Timestamps in the encoded JSON are ISO-8601; keys are sorted for
/// stable line ordering.
public actor FileAuditLog: AuditLog {
    private let url: URL
    private let encoder: JSONEncoder

    /// Creates a JSONL audit log at `url`. The file is created lazily
    /// on the first ``record(_:)`` call.
    public init(url: URL) {
        self.url = url
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        self.encoder = e
    }

    /// Appends `entry` as one JSON line. Swallows any backing-file
    /// failure (no throws, no propagation) — see protocol docs.
    public func record(_ entry: AuditEntry) async {
        guard let data = try? encoder.encode(entry) else { return }
        var line = data
        line.append(0x0A) // '\n'
        write(line: line)
    }

    /// Serialized inside actor isolation. Opens with `O_APPEND |
    /// O_CREAT | O_WRONLY` mode 0600, then `fchmod`s to 0600 to clamp
    /// any pre-existing looser permissions, then writes one line, then
    /// closes.
    private func write(line: Data) {
        let path = url.path
        let fd = path.withCString { cpath -> Int32 in
            open(cpath, O_APPEND | O_CREAT | O_WRONLY, 0o600)
        }
        guard fd >= 0 else { return }
        defer { close(fd) }

        // Clamp to 0600 on EVERY open, not just on creation.
        _ = fchmod(fd, 0o600)

        line.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var remaining = buf.count
            var ptr = base
            while remaining > 0 {
                let n = Foundation.write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if n == 0 { return }
                remaining -= n
                ptr = ptr.advanced(by: n)
            }
        }
    }
}
