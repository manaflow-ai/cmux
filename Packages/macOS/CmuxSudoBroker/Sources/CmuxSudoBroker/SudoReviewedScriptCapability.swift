import Darwin
import Foundation

/// Materializes reviewed bytes as an anonymous file descriptor.
struct SudoReviewedScriptCapability: Sendable {
    static let maximumBytes = SudoResourcePolicy.standard.maximumScriptBytes

    let bytes: Data
    let temporaryDirectoryURL: URL

    func withDescriptor<Value>(
        _ operation: (Int32) throws -> Value
    ) throws -> Value {
        guard bytes.count <= Self.maximumBytes else { throw Failure.tooLarge }
        var template = Array(
            temporaryDirectoryURL
                .appendingPathComponent(".cmux-sudo-reviewed.XXXXXX")
                .path
                .utf8CString
        )
        let writeDescriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress)
        }
        guard writeDescriptor >= 0 else { throw Failure.create(errno) }
        defer { Darwin.close(writeDescriptor) }

        let path = String(
            decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard unlink(path) == 0 else { throw Failure.unlink(errno) }
        guard fchmod(writeDescriptor, mode_t(0o600)) == 0 else {
            throw Failure.permissions(errno)
        }
        try writeAll(to: writeDescriptor)
        guard lseek(writeDescriptor, 0, SEEK_SET) == 0 else {
            throw Failure.readPosition(errno)
        }
        return try operation(writeDescriptor)
    }

    private func writeAll(to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw Failure.write(count == 0 ? EIO : errno)
            }
        }
    }

    private enum Failure: Error {
        case tooLarge
        case create(Int32)
        case permissions(Int32)
        case write(Int32)
        case unlink(Int32)
        case readPosition(Int32)
    }
}
