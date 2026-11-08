import Darwin
import Foundation

/// Shared POSIX plumbing for the Codex Teams launcher and supervisor.
struct CodexTeamsPOSIXSupport {
    static let watcherLifetimeFileDescriptor: Int32 = 9

    static func require(
        _ status: Int32,
        operation: String
    ) throws {
        guard status == 0 else {
            throw error(operation: operation, code: status)
        }
    }

    /// Returns a system-localized POSIX error; operation labels stay out of CLI
    /// output so internal process topology is not disclosed to callers.
    static func error(operation: String, code: Int32) -> POSIXError {
        _ = operation
        return POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) throws -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        pointers.reserveCapacity(strings.count + 1)
        defer {
            for pointer in pointers {
                if let pointer {
                    free(pointer)
                }
            }
        }
        for string in strings {
            guard !string.utf8.contains(0), let pointer = strdup(string) else {
                throw error(operation: "encode process arguments", code: EINVAL)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw error(operation: "encode process arguments", code: EINVAL)
            }
            return try body(baseAddress)
        }
    }
}
