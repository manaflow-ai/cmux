@testable import CmuxNextRemoteView
import CmuxNextWakeupsTestSupport
import Dispatch
import Foundation
import Testing

/// The rd transport registers the `remote-view.transport` lane and runs each job of its queue (a carrier event,
/// a caller's request, a timer fire) inside exactly one 1 s scope; a job waiting for the queue is in none, and
/// the lane is freed with the transport (plans/cmux-next/chrome-parity/p09-observability.md, section E, task 119).
/// Every depth is read on the transport's queue, so a timer's job can never run beside the read.
@Suite(.timeLimit(.minutes(1)))
struct RemoteRdTransportHangScopeTests {
    nonisolated static let lane = "remote-view.transport"

    /// A byte path that does nothing by itself: the test sends its events, and it reports how many scopes of
    /// the lane are open in `start` and in each `send` (both run on the transport's queue).
    nonisolated final class ProbeCarrier: RemoteRdByteCarrier {
        struct Start: Sendable {
            let queue: DispatchQueue
            let events: @Sendable (RemoteRdCarrierEvent) -> Void
            let depth: Int
        }

        private let hangs: RecordingLaneHangWatch
        let starts: AsyncStream<Start>
        private let started: AsyncStream<Start>.Continuation
        let sendDepths: AsyncStream<Int>
        private let sent: AsyncStream<Int>.Continuation

        init(hangs: RecordingLaneHangWatch) {
            self.hangs = hangs
            (starts, started) = AsyncStream.makeStream(of: Start.self)
            (sendDepths, sent) = AsyncStream.makeStream(of: Int.self)
        }

        var isBackedUp: Bool { false }

        func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void) {
            started.yield(Start(queue: queue, events: events, depth: hangs.open(RemoteRdTransportHangScopeTests.lane).count))
        }

        func send(_ bytes: Data) {
            sent.yield(hangs.open(RemoteRdTransportHangScopeTests.lane).count)
        }

        func cancel() {}
    }

    private static func transport(_ carrier: ProbeCarrier, hangs: RecordingLaneHangWatch) throws -> RemoteRdStreamTransport {
        let hello = RemoteRdHello(user: "u", install: "i", token: nil, service: RemoteRdStreamTransport.remoteBrowserService,
                                  caps: [RemoteRdStreamTransport.inputServiceCap])
        return try #require(RemoteRdStreamTransport(carrier: carrier, hello: hello, startKey: "tab", control: true, hangs: hangs))
    }

    @Test func eachQueueJobIsOneScopeAndAQueuedJobIsNone() async throws {
        let hangs = RecordingLaneHangWatch()
        let carrier = ProbeCarrier(hangs: hangs)
        let transport = try Self.transport(carrier, hangs: hangs)
        #expect(hangs.lanes == [Self.lane])
        #expect(RemoteRdStreamTransport.hangDeadline == .seconds(1))

        // The connect is a caller's job: the carrier starts inside its one scope.
        transport.connect()
        var starts = carrier.starts.makeAsyncIterator()
        let start = try #require(await starts.next())
        #expect(start.depth == 1)

        // A carrier event is one scope of its own: `.ready` sends hello and start from it.
        start.queue.async { start.events(.ready) }
        var sends = carrier.sendDepths.makeAsyncIterator()
        #expect(await sends.next() == 1)
        #expect(await sends.next() == 1)
        #expect(hangs.entered.allSatisfy { $0 == RecordingLaneHangWatch.Scope(lane: Self.lane, deadline: .seconds(1)) })

        // A job waiting for the queue is in no scope; once it runs it is in exactly one.
        await withCheckedContinuation { (suspended: CheckedContinuation<Void, Never>) in
            transport.queue.async {
                transport.queue.suspend()
                suspended.resume()
            }
        }
        let (depths, depth) = AsyncStream.makeStream(of: Int.self)
        transport.onQueue { depth.yield(hangs.open(Self.lane).count) }
        #expect(hangs.open(Self.lane).isEmpty, "a job waiting for the queue opened a scope")
        transport.queue.resume()
        var ran = depths.makeAsyncIterator()
        #expect(await ran.next() == 1)
        transport.stop()
    }

    @Test func theLaneIsFreedWithTheTransport() throws {
        let hangs = RecordingLaneHangWatch()
        var transport: RemoteRdStreamTransport? = try Self.transport(ProbeCarrier(hangs: hangs), hangs: hangs)
        #expect(transport != nil)
        #expect(hangs.unregistered.isEmpty)
        transport = nil
        #expect(hangs.unregistered == [Self.lane])
    }
}
