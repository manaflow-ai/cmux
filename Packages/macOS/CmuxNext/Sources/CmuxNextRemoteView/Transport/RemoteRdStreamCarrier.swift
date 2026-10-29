public import Foundation
import CmuxNextCompat

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
/// both directions; either direction ending ends the path (`.closed`), so the pane says why and
/// never waits.
///
/// The bytes queued for the stream and not yet written count against ``sendBound``, as the loopback
/// carriers' do: past it the carrier is backed up and the transport stops producing until `.writable`
/// (``RemoteRdByteCarrier``).
public nonisolated final class RemoteRdStreamCarrier: RemoteRdByteCarrier {
    /// The bytes queued for the stream and not yet written before the carrier is backed up: 4 MiB, as
    /// ``RemoteRdLoopbackCarrier/sendBound``.
    public static let sendBound = RemoteRdLoopbackCarrier.sendBound

    private let open: @Sendable () async throws -> RemoteRdByteStream
    private let outgoing: AsyncStream<Data>
    private let outbox: AsyncStream<Data>.Continuation
    private let unsent: ByteCreditWindow
    private let state = Mutex(State())

    private struct State {
        var events: (@Sendable (RemoteRdCarrierEvent) -> Void)?
        var queue: DispatchQueue?
        var task: Task<Void, Never>?
        var stream: RemoteRdByteStream?
        var cancelled = false
    }

    public init(sendBound: Int = RemoteRdStreamCarrier.sendBound,
                open: @escaping @Sendable () async throws -> RemoteRdByteStream) {
        self.open = open
        unsent = ByteCreditWindow(limit: sendBound)
        // concurrency-allow: bounded by `unsent`: the transport stops producing while ``isBackedUp``, so the stream holds at most `sendBound` plus one batch
        (outgoing, outbox) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    public var isBackedUp: Bool { unsent.isPaused }

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
                self.emit(.closed)
                return
            }
            guard self.adopt(stream) else {
                stream.close()
                return
            }
            self.emit(.ready)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    while let bytes = await stream.read() {
                        self.emit(.data(bytes))
                    }
                    self.emit(.closed)
                }
                group.addTask {
                    for await bytes in outgoing {
                        do {
                            try await stream.write(bytes)
                        } catch {
                            self.emit(.closed)
                            return
                        }
                        if self.unsent.consumed(bytes.count), self.unsent.resumeIfDrained() { self.emit(.writable) }
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
        _ = unsent.produced(bytes.count)
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

    private func emit(_ event: RemoteRdCarrierEvent) {
        let (events, queue) = state.withLock { ($0.events, $0.queue) }
        guard let events, let queue else { return }
        queue.async { events(event) }
    }
}
