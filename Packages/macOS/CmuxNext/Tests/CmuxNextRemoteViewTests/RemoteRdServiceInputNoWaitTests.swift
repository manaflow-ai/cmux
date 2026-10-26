import CmuxNextRemoteView
import Foundation
import os
import Testing

/// `RemoteRdStreamTransport.sendServiceInput` returns its input sequence number without waiting for the
/// transport queue (p02-threads-035): a remote browser key's turn on the main thread called it, and its
/// `queue.sync` waited for whatever the queue ran (an ingest of a large read, a stalled carrier send).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RemoteRdServiceInputNoWaitTests {
    /// A byte path that answers hello with a welcome listing `input.service` and started, and whose sends
    /// can be held: a held send holds the transport queue.
    nonisolated final class HostCarrier: RemoteRdByteCarrier {
        private let state = OSAllocatedUnfairLock(initialState: (holding: false, sent: 0))
        private let release = DispatchSemaphore(value: 0)
        let held: AsyncStream<Void>
        private let heldContinuation: AsyncStream<Void>.Continuation
        let sends: AsyncStream<Void>
        private let sendsContinuation: AsyncStream<Void>.Continuation

        init() {
            (held, heldContinuation) = AsyncStream.makeStream(of: Void.self)
            (sends, sendsContinuation) = AsyncStream.makeStream(of: Void.self)
        }

        var sentCount: Int { state.withLock { $0.sent } }

        func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void) {
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
            let hold = state.withLock { state -> Bool in
                state.sent += 1
                defer { state.holding = false }
                return state.holding
            }
            sendsContinuation.yield()
            guard hold else { return }
            heldContinuation.yield()
            release.wait()  // the test's own hold of the transport queue
        }

        func cancel() {}

        /// The next send holds the queue until ``open()``.
        func holdNextSend() { state.withLock { $0.holding = true } }
        func open() { release.signal() }
    }

    @Test func aServiceInputGetsItsNumberWhileTheQueueIsHeld() async throws {
        let carrier = HostCarrier()
        let transport = try #require(RemoteRdStreamTransport.remoteBrowser(carrier: carrier, user: "u", install: "i"))
        defer { transport.stop() }
        let statuses = transport.statusUpdates()
        transport.connect()
        for await status in statuses where status.state == .streaming { break }

        carrier.holdNextSend()
        transport.sendService(.object(["t": .string("rb.visibility"), "visible": .bool(true)]))
        var held = carrier.held.makeAsyncIterator()
        _ = await held.next()  // the transport queue is now held in the carrier's send
        let before = carrier.sentCount
        // Before p02-threads-035 this waited for the queue, so the test hit its time limit.
        let seq = transport.sendServiceInput(Data(#"{"t":"key"}"#.utf8), mustDeliver: true)
        #expect(seq != nil, "a session whose welcome lists input.service took no service input")
        let next = transport.sendServiceInput(Data(#"{"t":"key"}"#.utf8), mustDeliver: false)
        #expect(next.map { $0 > seq ?? 0 } == true, "service inputs are numbered in order")
        carrier.open()
        // The queue sends the inputs' packet after the hold.
        var sends = carrier.sends.makeAsyncIterator()
        while carrier.sentCount <= before { _ = await sends.next() }
        #expect(carrier.sentCount > before)
    }

    @Test func noServiceInputBeforeTheWelcome() throws {
        let carrier = HostCarrier()
        let transport = try #require(RemoteRdStreamTransport.remoteBrowser(carrier: carrier, user: "u", install: "i"))
        #expect(transport.sendServiceInput(Data(#"{"t":"key"}"#.utf8), mustDeliver: true) == nil)
    }
}
