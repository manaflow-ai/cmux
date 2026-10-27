import Foundation
import Darwin
import CmuxNextCompat
import CmuxNextTrace

/// The local PTY's read drain: what the read source and the last drain in `finish()` run on the read queue.
nonisolated extension LocalPTYTerminalIO {
    /// Drained: wait for readiness. Full: the consumer holds the window's limit, pause the read source.
    /// Hangup: the slave side closed.
    enum DrainResult { case drained, full, hangup }

    /// One `read(2)`'s outcome: a chunk went out or EINTR (read again), EAGAIN, the window is full, or
    /// the slave side closed.
    fileprivate enum ReadStep { case more, drained, full, hangup }

    /// The most bytes one `read(2)`, and so one ``readHangDeadline`` scope, takes.
    static let readChunkCapacity = 65_536

    /// Reads until EAGAIN (drained: wait for readiness), until `window` is full (the consumer holds its
    /// limit: pause), or until the slave side closed (0, EIO or another error: terminal). With `pauses`
    /// false (the last drain, after the shell exited) each chunk is counted in `window` but the drain
    /// reads to EAGAIN whatever the consumer holds. Each `read(2)` and the yield of its chunk is one
    /// scope of `watched`, so a shell that keeps the PTY full makes more scopes, never a longer one
    /// (Chrome bounds the work of one readiness callback the same way: mojo/core/channel_posix.cc,
    /// kMaxBatchReadCapacity). The descriptor is nonblocking, so no scope holds a wait for readiness.
    @discardableResult
    static func drain(_ fd: Int32, into continuation: AsyncStream<TerminalIOEvent>.Continuation,
                      watched: HangWatchedLane?, window: ByteCreditWindow? = nil, pauses: Bool = true,
                      chunkCapacity: Int = readChunkCapacity) -> DrainResult {
        var buffer = [UInt8](repeating: 0, count: chunkCapacity)
        // wakeup-allow: bounded: reads until EAGAIN (wait for readiness), a full window (pause) or hangup/EOF (terminal); EINTR retries
        while true {
            let step: ReadStep
            if let watched {
                step = watched.run { readChunk(fd, into: continuation, window: window, pauses: pauses, buffer: &buffer) }
            } else {
                step = readChunk(fd, into: continuation, window: window, pauses: pauses, buffer: &buffer)
            }
            switch step {
            case .more: continue
            case .drained: return .drained
            case .full: return .full
            case .hangup: return .hangup
            }
        }
    }

    /// One `read(2)` of at most `buffer.count` bytes; the chunk it read, if any, is counted in `window`
    /// and then yielded, so the window is full before the consumer can see the chunk that filled it.
    fileprivate static func readChunk(_ fd: Int32, into continuation: AsyncStream<TerminalIOEvent>.Continuation,
                                      window: ByteCreditWindow?, pauses: Bool, buffer: inout [UInt8]) -> ReadStep {
        let capacity = buffer.count
        // concurrency-allow: the PTY descriptor is O_NONBLOCK; read returns EAGAIN instead of waiting.
        // SAFETY: read writes at most `capacity` bytes, the array's count, into its storage,
        // alive for the call.
        let count = unsafe Darwin.read(fd, &buffer, capacity)
        if count > 0 {
            let full: Bool
            if pauses {
                full = window?.produced(count) == true
            } else {
                window?.producedPastWindow(count)
                full = false
            }
            if case .terminated = continuation.yield(.output(Data(buffer[0..<count]))) {
                // No one takes the stream any more: nothing to bound, so the PTY keeps draining.
                if full { _ = window?.releasePause() }
                return .more
            }
            return full ? .full : .more
        }
        if count < 0, errno == EINTR { return .more }
        return count < 0 && errno == EAGAIN ? .drained : .hangup
    }
}
