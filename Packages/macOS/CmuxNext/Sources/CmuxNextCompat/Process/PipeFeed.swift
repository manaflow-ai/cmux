public import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Hands bytes to a child's stdin pipe on a serial queue of its own, never on the caller's thread.
///
/// A pipe write can wait however small the bytes are: on a full pipe, and on a fresh one when the
/// kernel's pipe memory is used up (no buffer to put them in). A write on the caller's thread was
/// the NIGHTLY main-thread hang of 2026-11-09 (Cloud's spare warm wrote two tokens to
/// `cmux link start-chat` on the main actor and the main thread waited in `write` for 391 s). So
/// every write and the close go to this feed's queue, in order: the caller goes on at once, and a
/// child that never reads holds only this queue until it exits (its read end gone, the write fails
/// with EPIPE; `F_SETNOSIGPIPE` keeps that from raising SIGPIPE, which would end the app).
public final class PipeFeed: Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.cmuxterm.next.pipe-feed", qos: .utility)

    /// - Parameter handle: The write end of the child's stdin pipe. The feed owns it: close it with
    ///   ``close()``, never directly, so a close never races a write in flight.
    public init(_ handle: FileHandle) {
        self.handle = handle
        #if canImport(Darwin)
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
    }

    /// Queues `data`; a failed write (the child ended) is dropped, as the child is gone.
    public func write(_ data: Data) {
        queue.async { [handle] in
            Self.withoutSIGPIPE {
                // concurrency-allow: a pipe write on this feed's own queue, never the caller's thread (PipeFeed's doc)
                try? handle.write(contentsOf: data)
            }
        }
    }

    /// Queues `body` with the write end's descriptor: a caller that writes the bytes itself (a
    /// secret never copied into a `Data`). It runs on the feed's queue, in order with the rest.
    public func write(with body: @escaping @Sendable (Int32) -> Void) {
        queue.async { [handle] in Self.withoutSIGPIPE { body(handle.fileDescriptor) } }
    }

    /// Queues the close, after every queued write: the child reads to end of file.
    public func close() {
        queue.async { [handle] in try? handle.close() }
    }

    /// Runs `body` so that a write to a pipe whose reader is gone fails with EPIPE and never ends
    /// the process with SIGPIPE. Darwin has `F_SETNOSIGPIPE` on the descriptor (set in `init`).
    /// Linux has no per-descriptor switch: a pipe's SIGPIPE goes to the writing thread, so this
    /// blocks it on the feed's queue thread for the write, takes a SIGPIPE the write left pending,
    /// and restores the thread's mask.
    private static func withoutSIGPIPE(_ body: () -> Void) {
        #if canImport(Darwin)
        body()
        #else
        var pipeSet = sigset_t()
        sigemptyset(&pipeSet)
        sigaddset(&pipeSet, SIGPIPE)
        var wasPending = sigset_t()
        sigpending(&wasPending)
        let pendingBefore = sigismember(&wasPending, SIGPIPE) == 1
        var oldMask = sigset_t()
        pthread_sigmask(SIG_BLOCK, &pipeSet, &oldMask)
        body()
        var nowPending = sigset_t()
        sigpending(&nowPending)
        if !pendingBefore, sigismember(&nowPending, SIGPIPE) == 1 {
            var zero = timespec(tv_sec: 0, tv_nsec: 0)
            _ = sigtimedwait(&pipeSet, nil, &zero)
        }
        pthread_sigmask(SIG_SETMASK, &oldMask, nil)
        #endif
    }
}
