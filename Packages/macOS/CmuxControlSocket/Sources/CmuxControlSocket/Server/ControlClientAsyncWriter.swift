internal import Dispatch
public import Foundation
internal import Darwin

/// Asynchronously writes one connection's responses without parking a thread
/// when a client applies backpressure. One writer task owns the instance.
// @unchecked Sendable is safe because one connection task performs all writes;
// the one-shot writable source communicates only through its continuation.
public final class ControlClientAsyncWriter: @unchecked Sendable {
    private final class SourceBox: @unchecked Sendable {
        var source: (any DispatchSourceWrite)?
    }

    private let socket: Int32
    /// One-shot writable sources must finish cancellation before the owner
    /// closes the shared socket descriptor.
    let sourceCancellationBarrier = DispatchSourceCancellationBarrier()

    /// Creates a writer over a non-blocking descriptor.
    ///
    /// - Parameter socket: A borrowed descriptor retained by the connection owner.
    public init(socket: Int32) {
        self.socket = socket
        _ = Self.makeNonBlocking(socket)
    }

    /// Writes all bytes, suspending on `EAGAIN`; returns false after EOF,
    /// cancellation, or a non-retryable write error.
    public func writeAll(_ data: Data) async -> Bool {
        var offset = 0
        while offset < data.count, !Task.isCancelled {
            let written = data.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(
                    socket,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                guard await waitForWritable() else { return false }
                continue
            }
            return false
        }
        return offset == data.count
    }

    /// Waits for any one-shot writable source to finish cancellation.
    ///
    /// Call after the owning write task has returned. To interrupt a write,
    /// cancel that task first; this method does not cancel an in-flight write.
    public func cancelAndWait() async {
        await sourceCancellationBarrier.wait()
    }

    /// Enables would-block handling instead of parking the connection task.
    private static func makeNonBlocking(_ socket: Int32) -> Int32? {
        let flags = fcntl(socket, F_GETFL, 0)
        guard flags >= 0 else { return errno }
        guard fcntl(socket, F_SETFL, flags | O_NONBLOCK) >= 0 else { return errno }
        return nil
    }

    /// Joins cancellation of a one-shot source on readiness or task cancellation.
    private func waitForWritable() async -> Bool {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let streamContinuation = stream.continuation
        let sourceBox = SourceBox()
        let writeSource = DispatchSource.makeWriteSource(
            fileDescriptor: socket,
            queue: DispatchQueue.global(qos: .utility)
        )
        sourceCancellationBarrier.register()
        writeSource.setEventHandler { [streamContinuation, sourceBox] in
            streamContinuation.yield(())
            streamContinuation.finish()
            sourceBox.source?.cancel()
        }
        writeSource.setCancelHandler { [sourceCancellationBarrier] in
            streamContinuation.finish()
            sourceCancellationBarrier.complete()
        }
        sourceBox.source = writeSource
        writeSource.activate()

        var iterator = stream.stream.makeAsyncIterator()
        let writable: Void? = await withTaskCancellationHandler {
            await iterator.next()
        } onCancel: {
            sourceBox.source?.cancel()
            streamContinuation.finish()
        }
        // The event/cancellation handler may have resumed the iterator before
        // libdispatch ran the source's cancellation handler. Await here while
        // the source is still retained, so a subsequent socket close cannot
        // race the kevent teardown.
        writeSource.cancel()
        await sourceCancellationBarrier.wait()
        return writable != nil
    }
}
