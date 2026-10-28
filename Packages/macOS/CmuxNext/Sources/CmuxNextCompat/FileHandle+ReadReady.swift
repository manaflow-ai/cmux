internal import Darwin
public import Foundation

/// What one read of a pipe's ready bytes gave (``Foundation/FileHandle/readReady(maxLength:)``).
public enum PipeRead: Equatable, Sendable {
    /// Bytes that were ready.
    case bytes(Data)
    /// Nothing yet (EINTR, EAGAIN): the handler runs again when bytes arrive.
    case retry
    /// End of file, or a read that failed: the stream is over. Clear the handler.
    case end
}

extension FileHandle {
    /// One `read(2)` of the bytes ready on this handle, for a `readabilityHandler`. Unlike
    /// `availableData`, a failed read (EBADF or EIO, for example a descriptor closed under a live
    /// handler while its process is stopped) ends the stream instead of raising an Objective-C
    /// exception Swift cannot catch, which aborts the app (cmuxterm-hq#4753).
    public nonisolated func readReady(maxLength: Int = 64 * 1024) -> PipeRead {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
        if count > 0 { return .bytes(Data(buffer[..<count])) }
        if count < 0, errno == EINTR || errno == EAGAIN { return .retry }
        return .end
    }
}
