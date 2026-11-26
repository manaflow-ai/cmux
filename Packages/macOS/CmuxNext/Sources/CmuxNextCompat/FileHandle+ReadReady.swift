#if canImport(Darwin)
internal import Darwin
#else
internal import Glibc
#endif
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
        #if canImport(Darwin)
        let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
        #else
        let count = Glibc.read(fileDescriptor, &buffer, buffer.count)
        #endif
        if count > 0 { return .bytes(Data(buffer[..<count])) }
        if count < 0, errno == EINTR || errno == EAGAIN { return .retry }
        return .end
    }
}

extension FileHandle {
    /// The most chunks ``readyChunks()`` holds for a consumer that has not read them yet.
    public static let readyChunksLimit = 256

    /// This handle's bytes as they arrive, each chunk one ``readReady(maxLength:)`` of a
    /// `readabilityHandler` (a dispatch source of this handle's own). Not `bytes`: Foundation reads
    /// every `FileHandle.AsyncBytes` in the process one at a time, so a `bytes` reader waiting on
    /// a quiet pipe keeps every other one from reading (macOS 26: with one idle `bytes` reader in
    /// the process, a line written to a second pipe was not read in 5 s).
    ///
    /// Stop condition: the stream ends at end of file or a failed read, or when a consumer falls
    /// more than ``readyChunksLimit`` chunks behind (bytes are never dropped from the middle).
    /// Cleanup: the handler is cleared whenever the stream ends: at end of file, when its consumer's
    /// task is cancelled, when the stream is released (a consumer that breaks out and drops it),
    /// and on `stop()`, for an owner that goes away before its end of file.
    public nonisolated func readyChunks() -> (chunks: AsyncStream<Data>, stop: @Sendable () -> Void) {
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(Self.readyChunksLimit))
        continuation.onTermination = { [weak self] _ in self?.readabilityHandler = nil }
        readabilityHandler = { handle in
            switch handle.readReady() {
            case .bytes(let data):
                if case .dropped(_) = continuation.yield(data) {
                    // Nobody reads this pipe any more: close it, so the writer gets EPIPE instead of filling
                    // it to 64 KB and waiting there for good (cmuxterm-hq#8747: 452 full pipes).
                    handle.readabilityHandler = nil
                    try? handle.close()
                    continuation.finish()
                }
                #if !canImport(Darwin)
                // The non-Darwin readability source may report the last bytes and the writer's close as one
                // event and not fire again, so an end of file already waiting ends the stream now.
                if handle.readabilityHandler != nil, handle.endOfFileIsWaiting() {
                    handle.readabilityHandler = nil
                    continuation.finish()
                }
                #endif
            case .retry:
                break
            case .end:
                handle.readabilityHandler = nil
                continuation.finish()
            }
        }
        return (chunks, { continuation.finish() })
    }
}

#if !canImport(Darwin)
extension FileHandle {
    /// True when the writer has closed and nothing is left to read: the next `read(2)` would return end of file.
    nonisolated func endOfFileIsWaiting() -> Bool {
        var pending = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&pending, 1, 0) == 1, pending.revents & Int16(POLLHUP) != 0 else { return false }
        var available: Int32 = 0
        return ioctl(fileDescriptor, UInt(FIONREAD), &available) == 0 && available == 0
    }
}
#endif
