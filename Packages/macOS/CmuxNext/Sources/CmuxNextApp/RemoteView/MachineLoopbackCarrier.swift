import CmuxNextDaemon
import CmuxNextRemoteLocalhostService
import CmuxNextRemoteView
import Foundation
import CmuxNextCompat

/// The rd byte path to a browser host on another machine's loopback: one
/// `loopback-forward-v1` stream over that machine's daemon link (cx-2cob
/// slice 2). It adds no listener on either side. The stream opens when the
/// transport starts; a failed open, a host that closes, or a lost link ends
/// the session (`.closed`), so the tab says why and never waits.
///
/// Bounds, both directions: bytes from the host stay within the stream's
/// receive window (``LoopbackStream``), whose credit goes back only once the
/// transport took them. Bytes to the host wait in the outbox for the
/// daemon's credit; past ``outboxBound`` the host has stopped taking them,
/// and the path ends (`.closed`) instead of buffering without limit, as a
/// control connection drops a client that stopped reading
/// (`ControlConnection`'s `maxOutboxBytes`).
nonisolated final class MachineLoopbackCarrier: RemoteRdByteCarrier {
    /// The bytes `send` may queue that the stream has not written yet: 4 MiB,
    /// 16 of the daemon's 256 KiB windows.
    static let outboxBound = 4 << 20

    private let open: @Sendable () async throws -> LoopbackStream
    private let outgoing: AsyncStream<Data>
    private let outbox: AsyncStream<Data>.Continuation
    private let bound: Int
    private let state = Mutex(State())

    private struct State {
        var events: (@Sendable (RemoteRdCarrierEvent) -> Void)?
        var queue: DispatchQueue?
        var task: Task<Void, Never>?
        var stream: LoopbackStream?
        var cancelled = false
        /// Bytes `send` queued that the stream has not written yet.
        var outboxBytes = 0
        /// The outbox passed the bound: the path ended and later sends are dropped.
        var overflowed = false
    }

    /// - Parameters:
    ///   - outboxBound: The bytes `send` may queue that the stream has not written yet.
    ///   - open: Opens the stream when the transport starts.
    init(outboxBound: Int = MachineLoopbackCarrier.outboxBound, open: @escaping @Sendable () async throws -> LoopbackStream) {
        self.open = open
        bound = max(outboxBound, 1)
        // concurrency-allow: the transport's frames in send order; send() ends the path past outboxBound
        // memory: bounded-by outboxBound (4 MiB): send() ends the path instead of queueing past it
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
                        self.state.withLock { $0.outboxBytes -= bytes.count }
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

    /// Queues `bytes` for the host. Past ``outboxBound`` unwritten bytes the
    /// path ends (`.closed`, once) and these and later bytes are dropped.
    func send(_ bytes: Data) {
        let admission = state.withLock { state -> OutboxAdmission in
            guard !state.cancelled, !state.overflowed else { return .dropped }
            guard state.outboxBytes + bytes.count <= bound else {
                state.overflowed = true
                return .overflowed(state.stream)
            }
            state.outboxBytes += bytes.count
            return .queued
        }
        switch admission {
        case .queued:
            outbox.yield(bytes)
        case .dropped:
            break
        case .overflowed(let stream):
            emit(.closed)
            outbox.finish()
            stream?.close()
        }
    }

    /// What ``send(_:)`` does with one frame.
    private nonisolated enum OutboxAdmission {
        case queued
        case dropped
        /// The frame would pass the bound: the path ends; the stream, when one is open, closes.
        case overflowed(LoopbackStream?)
    }

    /// Bytes `send` queued that the stream has not written yet (tests).
    var queuedOutboxBytes: Int { state.withLock(\.outboxBytes) }

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
