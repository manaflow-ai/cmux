import Foundation
import Darwin
import CmuxNextTrace

/// The local PTY's read drain: what the read source and the last drain in `finish()` run on the read queue.
nonisolated extension LocalPTYTerminalIO {
    enum DrainResult { case drained, hangup }

    /// One `read(2)`'s outcome: a chunk went out or EINTR (read again), EAGAIN, or the slave side closed.
    fileprivate enum ReadStep { case more, drained, hangup }

    /// The most bytes one `read(2)`, and so one ``readHangDeadline`` scope, takes.
    static let readChunkCapacity = 65_536

    /// Reads until EAGAIN (drained: wait for readiness) or until the slave side closed (0, EIO or another
    /// error: terminal). Each `read(2)` and the yield of its chunk is one scope of `watched`, so a shell
    /// that keeps the PTY full makes more scopes, never a longer one (Chrome bounds the work of one
    /// readiness callback the same way: mojo/core/channel_posix.cc, kMaxBatchReadCapacity). The descriptor
    /// is nonblocking, so no scope holds a wait for readiness.
    @discardableResult
    static func drain(_ fd: Int32, into continuation: AsyncStream<TerminalIOEvent>.Continuation,
                      watched: HangWatchedLane?, chunkCapacity: Int = readChunkCapacity) -> DrainResult {
        var buffer = [UInt8](repeating: 0, count: chunkCapacity)
        // wakeup-allow: bounded: reads until EAGAIN (wait for readiness) or hangup/EOF (terminal); EINTR retries
        while true {
            let step: ReadStep
            if let watched {
                step = watched.run { readChunk(fd, into: continuation, buffer: &buffer) }
            } else {
                step = readChunk(fd, into: continuation, buffer: &buffer)
            }
            switch step {
            case .more: continue
            case .drained: return .drained
            case .hangup: return .hangup
            }
        }
    }

    /// One `read(2)` of at most `buffer.count` bytes; the chunk it read, if any, is yielded.
    fileprivate static func readChunk(_ fd: Int32, into continuation: AsyncStream<TerminalIOEvent>.Continuation,
                                      buffer: inout [UInt8]) -> ReadStep {
        let capacity = buffer.count
        // concurrency-allow: the PTY descriptor is O_NONBLOCK; read returns EAGAIN instead of waiting.
        // SAFETY: read writes at most `capacity` bytes, the array's count, into its storage,
        // alive for the call.
        let count = unsafe Darwin.read(fd, &buffer, capacity)
        if count > 0 {
            continuation.yield(.output(Data(buffer[0..<count])))
            return .more
        }
        if count < 0, errno == EINTR { return .more }
        return count < 0 && errno == EAGAIN ? .drained : .hangup
    }
}
