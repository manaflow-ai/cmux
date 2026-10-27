public import Foundation
import Darwin

extension FileHandle {
    /// What one ``readAvailable(upToCount:fileID:line:)`` call found.
    public enum AvailableRead: Sendable, Equatable {
        /// The bytes the descriptor had; never empty.
        case bytes(Data)
        /// The stream ended: the writers closed it, or it can no longer be read.
        case end(AvailableReadEnd)
    }

    /// Why a stream ended.
    public enum AvailableReadEnd: Error, Sendable, Equatable {
        /// `read(2)` returned 0: every writer closed the pipe (the child exited or was killed).
        case endOfFile
        /// `read(2)` failed with this errno (EBADF when the handle was closed under the reader, EIO).
        case failed(errno: Int32)
    }

    /// The most bytes one ``readAvailable(upToCount:fileID:line:)`` call takes by default; a readability handler
    /// that leaves more in the pipe runs again at once.
    public static let availableReadSize = 64 * 1024

    /// The bytes readable now, without the Objective-C exception of FileHandle's legacy read: one `read(2)` of at
    /// most `count` bytes on ``fileDescriptor`` (retried on EINTR). Chromium answers a readiness callback
    /// (`OnFileCanReadWithoutBlocking`, base/message_loop/message_pump_epoll.cc) the same way, with one
    /// `base::File::ReadAtCurrentPosNoBestEffort` (`HANDLE_EINTR(read(...))`, base/files/file_posix.cc).
    /// The legacy read raises `NSFileHandleOperationException` when `read(2)` fails (a handle closed under its
    /// readability handler, a child killed mid-write); this answers ``AvailableRead/end(_:)`` instead.
    ///
    /// Call it from a `readabilityHandler` (the descriptor is readable, so it does not wait) or a thread that may
    /// wait: it goes through ``blockingRead(_:_:_:fileID:line:)``, which reports a call on the main thread.
    ///
    /// - Parameters:
    ///   - count: The most bytes to read; values below 1 read 1.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The bytes, or the end of the stream with its reason.
    public func readAvailable(upToCount count: Int = FileHandle.availableReadSize,
                              fileID: StaticString = #fileID, line: UInt = #line) -> AvailableRead {
        let descriptor = fileDescriptor
        // SAFETY: a scratch buffer that lives only for the closure; read(2) writes at most buffer.count bytes into
        // it, and only the `result` bytes it reports written are copied out.
        return unsafe withUnsafeTemporaryAllocation(byteCount: max(count, 1), alignment: 1) {
            (buffer: UnsafeMutableRawBufferPointer) -> AvailableRead in
            guard let base = unsafe buffer.baseAddress else { return .end(.failed(errno: ENOMEM)) }
            // A signal can interrupt the read before it moved a byte; each retry is one more read, never a poll.
            var result = unsafe CmuxNextCompat.blockingRead(descriptor, base, buffer.count, fileID: fileID, line: line)
            while result < 0 && errno == EINTR {
                result = unsafe CmuxNextCompat.blockingRead(descriptor, base, buffer.count, fileID: fileID, line: line)
            }
            if result > 0 { return .bytes(unsafe Data(bytes: base, count: result)) }
            return .end(result == 0 ? .endOfFile : .failed(errno: errno))
        }
    }
}
