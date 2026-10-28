import CmuxNextCompat
@testable import CmuxNextRemoteView
import Foundation
import Testing

/// While its carrier is backed up (``RemoteRdByteCarrier/isBackedUp``) the transport sends none of the
/// frames it produces: the caller's input stays in its outbox until the carrier says `.writable`, then
/// reaches the host in order, with no frame lost. The carriers queued without limit,
/// and the bounded one ended the session past its bound instead.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteRdCarrierBackpressureTests {
    /// A byte path that answers hello with a welcome listing `input.service` and started, and whose
    /// backup the test sets.
    nonisolated final class GatedCarrier: RemoteRdByteCarrier {
        private struct State {
            var backedUp = false
            var frames: [Data] = []
            var queue: DispatchQueue?
            var events: (@Sendable (RemoteRdCarrierEvent) -> Void)?
        }

        private let state = Mutex(State())
        let sends: AsyncStream<Void>
        private let sendsContinuation: AsyncStream<Void>.Continuation

        init() {
            (sends, sendsContinuation) = AsyncStream.makeStream(of: Void.self)
        }

        /// Every frame sent, in order.
        var frames: [Data] { state.withLock(\.frames) }
        var isBackedUp: Bool { state.withLock(\.backedUp) }

        func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void) {
            state.withLock { state in
                state.queue = queue
                state.events = events
            }
            events(.ready)
            let welcome = RemoteRdWelcome(encoder: "test", width: 1, height: 1, maxDatagram: 1152, carrier: "stream",
                                          service: RemoteRdStreamTransport.remoteBrowserService,
                                          caps: [RemoteRdStreamTransport.inputServiceCap])
            var bytes = Data()
            for control in [RemoteRdControl.welcome(welcome), .started(session: 1)] {
                if let json = try? control.json(), let frame = try? RemoteRdCore.streamFrame(json, control: true) {
                    bytes.append(frame)
                }
            }
            events(.data(bytes))
        }

        func send(_ bytes: Data) {
            state.withLock { $0.frames.append(bytes) }
            sendsContinuation.yield()
        }

        func cancel() {}

        func backUp() {
            state.withLock { $0.backedUp = true }
        }

        /// Ends the backup and tells the transport, on its queue, as a carrier that drained does.
        func drain() {
            let (queue, events) = state.withLock { state in
                state.backedUp = false
                return (state.queue, state.events)
            }
            guard let queue, let events else { return }
            queue.async { events(.writable) }
        }
    }

    @Test func aBackedUpCarrierHoldsTheCallersFramesUntilWritable() async throws {
        let carrier = GatedCarrier()
        let transport = try #require(RemoteRdStreamTransport.remoteBrowser(carrier: carrier, user: "u", install: "i"))
        defer { transport.stop() }
        let statuses = transport.statusUpdates()
        transport.connect()
        for await status in statuses where status.state == .streaming { break }

        carrier.backUp()
        let keys = ["held-key-1", "held-key-2", "held-key-3"]
        for key in keys {
            #expect(transport.sendServiceInput(Data(#"{"t":"\#(key)"}"#.utf8), mustDeliver: true) != nil)
        }
        // Each input queued a pump; this runs after them on the transport queue.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in transport.queue.async { done.resume() } }
        #expect(!carrier.frames.contains { frame in keys.contains { frame.range(of: Data($0.utf8)) != nil } },
                "an input frame went to a backed-up carrier")

        carrier.drain()
        let last = Data("held-key-3".utf8)
        var sends = carrier.sends.makeAsyncIterator()
        while !carrier.frames.contains(where: { $0.range(of: last) != nil }) { _ = await sends.next() }
        let frames = carrier.frames
        let positions = keys.map { key in frames.firstIndex { $0.range(of: Data(key.utf8)) != nil } }
        #expect(positions.allSatisfy { $0 != nil }, "an input held back was lost")
        let found = positions.compactMap { $0 }
        #expect(found == found.sorted(), "the held inputs reached the host out of order")
    }
}
