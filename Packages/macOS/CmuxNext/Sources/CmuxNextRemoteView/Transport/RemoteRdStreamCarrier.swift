public import Foundation
import CmuxNextCompat
import os

/// An ordered byte stream an rd carrier rides, given as closures by whoever opened it (the app's
/// Cloud tunnel to a machine's `cmux-rd` host), so this module needs no transport of its own.
public nonisolated struct RemoteRdByteStream: Sendable {
    /// The next bytes from the host; nil once the stream ended.
    public let read: @Sendable () async -> Data?
    public let write: @Sendable (Data) async throws -> Void
    public let close: @Sendable () -> Void

    public init(read: @escaping @Sendable () async -> Data?, write: @escaping @Sendable (Data) async throws -> Void,
                close: @escaping @Sendable () -> Void) {
        self.read = read
        self.write = write
        self.close = close
    }
}

/// The rd byte path over a `RemoteRdByteStream`: opens it when the transport starts, then copies
/// both directions; either direction ending ends the path (`.closed(reason:)`), so the pane says why and
/// never waits.
public nonisolated final class RemoteRdStreamCarrier: RemoteRdByteCarrier {
    private let open: @Sendable () async throws -> RemoteRdByteStream
    private let outgoing: AsyncStream<Data>
    private let outbox: AsyncStream<Data>.Continuation
    private let state = Mutex(State())

    private struct State {
        var events: (@Sendable (RemoteRdCarrierEvent) -> Void)?
        var queue: DispatchQueue?
        var task: Task<Void, Never>?
        var stream: RemoteRdByteStream?
        var cancelled = false
        /// This side closed the stream (a failed write), so the read ending after it is not the host's.
        var closedHere = false
    }

    public init(open: @escaping @Sendable () async throws -> RemoteRdByteStream) {
        self.open = open
        // concurrency-allow: the transport's frames in send order; the transport paces them as it does for NWConnection's send queue
        (outgoing, outbox) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    public func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void) {
        state.withLock { state in
            state.events = events
            state.queue = queue
        }
        let outgoing = outgoing
        // task-owner: the carrier's one stream; ends when the stream ends or cancel() cancels it.
        let task = Task { [open] in
            let stream: RemoteRdByteStream
            do {
                stream = try await open()
            } catch {
                // The open's own error (no link, a refused lookup or dial) is why the pane says the
                // connection was lost: the closed event carries it to the session snapshot.
                let reason = "rd stream did not open: \(String(describing: error))"
                Self.logger.error("\(reason, privacy: .public)")
                self.emit(.closed(reason: reason))
                return
            }
            guard self.adopt(stream) else {
                stream.close()
                return
            }
            self.emit(.ready)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    var received = 0
                    while let bytes = await stream.read() {
                        received += bytes.count
                        self.emit(.data(bytes))
                    }
                    // A read also ends when this side closed the stream (cancel(), a failed write): only an end
                    // nobody here asked for is the host's.
                    if self.state.withLock({ $0.cancelled || $0.closedHere }) {
                        self.emit(.closed(reason: "rd stream closed by this side"))
                    } else {
                        let reason = "rd stream ended by the host after \(received) bytes"
                        Self.logger.notice("\(reason, privacy: .public)")
                        self.emit(.closed(reason: reason))
                    }
                }
                group.addTask {
                    for await bytes in outgoing {
                        do {
                            try await stream.write(bytes)
                        } catch {
                            let reason = "rd stream write failed: \(String(describing: error))"
                            Self.logger.error("\(reason, privacy: .public)")
                            self.state.withLock { $0.closedHere = true }
                            self.emit(.closed(reason: reason))
                            return
                        }
                    }
                }
                await group.next()
                stream.close()
                group.cancelAll()
            }
        }
        state.withLock { $0.task = task }
    }

    public func send(_ bytes: Data) {
        outbox.yield(bytes)
    }

    public func cancel() {
        let (task, stream) = state.withLock { state in
            state.cancelled = true
            state.events = nil
            return (state.task, state.stream)
        }
        outbox.finish()
        stream?.close()
        task?.cancel()
    }

    private func adopt(_ stream: RemoteRdByteStream) -> Bool {
        state.withLock { state in
            guard !state.cancelled else { return false }
            state.stream = stream
            return true
        }
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "remote-view-rd")

    private func emit(_ event: RemoteRdCarrierEvent) {
        let (events, queue) = state.withLock { ($0.events, $0.queue) }
        guard let events, let queue else { return }
        queue.async { events(event) }
    }
}
