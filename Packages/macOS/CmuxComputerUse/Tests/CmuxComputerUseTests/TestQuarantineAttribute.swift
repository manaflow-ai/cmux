import Darwin
import Foundation

/// Raw access to `com.apple.quarantine` for tests.
///
/// Gatekeeper reads the extended attribute itself, so assertions go through
/// `getxattr(2)` rather than Foundation's `quarantineProperties` view, which
/// is derived from the record and differs between macOS releases.
struct TestQuarantineAttribute {
    /// The extended attribute LaunchServices stores quarantine state in.
    static let name = "com.apple.quarantine"

    /// A failed `setxattr(2)` or `getxattr(2)` call.
    struct CallError: Error, CustomStringConvertible {
        let call: String
        let path: String
        let code: Int32

        var description: String {
            "\(call) failed for \(path): errno \(code)"
        }
    }

    /// A web-download record in LaunchServices' `flags;time;agent;uuid` format.
    ///
    /// The timestamp is fixed so a test never depends on the wall clock.
    static func webDownloadRecord(agent: String = "CmuxComputerUseTests") -> String {
        "0081;6ab30fce;\(agent);\(UUID().uuidString)"
    }

    /// Writes `record` on `url` itself with `setxattr(2)`, never following a symbolic link.
    static func apply(_ record: String, to url: URL) throws {
        let status = record.withCString { value in
            setxattr(url.path, name, value, strlen(value), 0, XATTR_NOFOLLOW)
        }
        guard status == 0 else {
            throw CallError(call: "setxattr", path: url.path, code: errno)
        }
    }

    /// Reads the raw record on `url` itself, or nil when the attribute is absent.
    static func record(at url: URL) throws -> String? {
        var buffer = [CChar](repeating: 0, count: 1_024)
        let length = getxattr(url.path, name, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        if length < 0 {
            let code = errno
            guard code == ENOATTR else {
                throw CallError(call: "getxattr", path: url.path, code: code)
            }
            return nil
        }
        return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
