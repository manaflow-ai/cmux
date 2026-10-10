import CmuxNextDaemon
import CmuxNextRemoteView
import Foundation
import Synchronization

/// The rd byte path to a browser host on another machine's loopback: one
/// `loopback-forward-v1` stream over that machine's daemon link (cx-2cob
/// slice 2). It adds no listener on either side. The stream opens when the
/// transport starts; a failed open, a host that closes, or a lost link ends
/// the session (`.closed`), so the tab says why and never waits.
nonisolated final class MachineLoopbackCarrier: RemoteRdByteCarrier {
    private let open: @Sendable () async throws -> LoopbackStream
    private let outgoing: AsyncStream<Data>
    private let outbox: AsyncStream<Data>.Continuation
    private let state = Mutex(State())

    private struct State {
        var events: (@Sendable (RemoteRdCarrierEvent) -> Void)?
        var queue: DispatchQueue?
        var task: Task<Void, Never>?
        var stream: LoopbackStream?
        var cancelled = false
    }

    init(open: @escaping @Sendable () async throws -> LoopbackStream) {
        self.open = open
        // concurrency-allow: the transport's frames in send order; the transport paces them as it does for NWConnection's send queue
        (outgoing, outbox) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void) {
        state.withLock { state in
            state.events = events
            state.queue = queue
        }
        let outgoing = outgoing
        // task-owner: the carrier's one stream; ends when the stream ends or cancel() cancels it.
        let task = Task { [open] in
            let stream: LoopbackStream
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
                    for await event in stream.events {
                        switch event {
                        case .data(let bytes): self.emit(.data(bytes)) { stream.consumed(bytes.count) }
                        case .eof, .closed: self.emit(.closed)
                        }
                    }
                }
                group.addTask {
                    for await bytes in outgoing {
                        do {
                            try await stream.write(bytes)
                        } catch {
                            self.emit(.closed)
                            return
                        }
                    }
                }
                // Either direction ending ends the path.
                await group.next()
                stream.close()
                group.cancelAll()
            }
        }
        state.withLock { $0.task = task }
    }

    func send(_ bytes: Data) {
        outbox.yield(bytes)
    }

    func cancel() {
        let (task, stream) = state.withLock { state in
            state.cancelled = true
            state.events = nil
            return (state.task, state.stream)
        }
        outbox.finish()
        stream?.close()
        task?.cancel()
    }

    private func adopt(_ stream: LoopbackStream) -> Bool {
        state.withLock { state in
            guard !state.cancelled else { return false }
            state.stream = stream
            return true
        }
    }

    /// Runs the event on the transport's queue, then `after` (credit back
    /// to the daemon once the bytes are taken).
    private func emit(_ event: RemoteRdCarrierEvent, after: (@Sendable () -> Void)? = nil) {
        let (events, queue) = state.withLock { ($0.events, $0.queue) }
        guard let events, let queue else { return }
        queue.async {
            events(event)
            after?()
        }
    }
}

extension RemoteLocalhostService {
    /// The rd byte path to `port` on `machine`'s loopback. A machine with no
    /// daemon here gives a carrier that ends at once (the tab says why).
    func browserCarrier(machine: String, port: UInt16) -> MachineLoopbackCarrier {
        let opener = loopbackOpener(machine: machine)
        return MachineLoopbackCarrier {
            guard let opener else { throw LoopbackForwardError.unavailable(machine) }
            return try await opener(port)
        }
    }
}
