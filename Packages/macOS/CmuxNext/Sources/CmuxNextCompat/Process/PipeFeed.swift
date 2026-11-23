public import Foundation
import Darwin

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
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// Queues `data`; a failed write (the child ended) is dropped, as the child is gone.
    public func write(_ data: Data) {
        queue.async { [handle] in
            // concurrency-allow: a pipe write on this feed's own queue, never the caller's thread (PipeFeed's doc)
            try? handle.write(contentsOf: data)
        }
    }

    /// Queues `body` with the write end's descriptor: a caller that writes the bytes itself (a
    /// secret never copied into a `Data`). It runs on the feed's queue, in order with the rest.
    public func write(with body: @escaping @Sendable (Int32) -> Void) {
        queue.async { [handle] in body(handle.fileDescriptor) }
    }

    /// Queues the close, after every queued write: the child reads to end of file.
    public func close() {
        queue.async { [handle] in try? handle.close() }
    }
}
