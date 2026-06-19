import Darwin
import Foundation

/// One-shot file-descriptor bridge for main-actor async socket replies.
///
/// The control socket still has a synchronous, line-in/line-out contract on a
/// dedicated client thread. Async auth commands encode their complete response
/// on the main actor, write the response bytes into this pipe, and let the
/// client thread block in `read` until those bytes arrive.
///
/// `@unchecked Sendable` is sound because the instance stores immutable file
/// descriptor integers; Darwin owns synchronization between the read and write
/// ends, and no Swift mutable payload is shared across threads.
nonisolated final class SocketAsyncResponsePipe: @unchecked Sendable {
    private static let maximumResponseBytes = 16 * 1024 * 1024

    private let readFD: Int32
    private let writeFD: Int32

    init?() {
        var fds = [Int32](repeating: -1, count: 2)
        guard pipe(&fds) == 0 else { return nil }
        readFD = fds[0]
        writeFD = fds[1]
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
    }

    deinit {
        close(readFD)
        close(writeFD)
    }

    func complete(_ response: String) {
        let bytes = Array(response.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumResponseBytes else {
            writeLength(0)
            return
        }

        writeLength(UInt64(bytes.count))
        _ = bytes.withUnsafeBytes(writeAll(_:))
    }

    private func writeLength(_ length: UInt64) {
        var encodedLength = length.bigEndian
        _ = withUnsafeBytes(of: &encodedLength, writeAll(_:))
    }

    func wait() -> String? {
        var encodedLength: UInt64 = 0
        guard withUnsafeMutableBytes(of: &encodedLength, readExact(into:)) else {
            return nil
        }
        let responseLength = UInt64(bigEndian: encodedLength)
        guard responseLength > 0,
              responseLength <= Self.maximumResponseBytes,
              let byteCount = Int(exactly: responseLength) else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard bytes.withUnsafeMutableBytes({ readExact(into: $0) }) else {
            return nil
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private func readExact(into buffer: UnsafeMutableRawBufferPointer) -> Bool {
        guard let baseAddress = buffer.baseAddress else {
            return buffer.isEmpty
        }

        var offset = 0
        while offset < buffer.count {
            let result = Darwin.read(readFD, baseAddress.advanced(by: offset), buffer.count - offset)
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else {
                return false
            }
            offset += result
        }
        return true
    }

    private func writeAll(_ buffer: UnsafeRawBufferPointer) -> Bool {
        guard let baseAddress = buffer.baseAddress else {
            return buffer.isEmpty
        }

        var offset = 0
        while offset < buffer.count {
            let result = Darwin.write(writeFD, baseAddress.advanced(by: offset), buffer.count - offset)
            if result < 0, errno == EINTR {
                continue
            }
            guard result > 0 else {
                return false
            }
            offset += result
        }
        return true
    }
}
