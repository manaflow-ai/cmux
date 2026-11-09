import CmuxNextCompat
@testable import CmuxNextRemoteView
import CmuxNextRemoteViewSessions
import Foundation
import Testing

/// The Chief card's Computer section frames (cmux issues 31488, 34263): one view-mode `cmux-rd`
/// session over the carrier's desktop service; `ended` runs once when the session ends by itself,
/// never synchronously from `start` and never after `stop`.
@MainActor
@Suite struct CloudDesktopFramesTests {
    private struct NoLink: Error {}

    /// Records what the transport sends; `.ready` opens the path.
    nonisolated final class RecordingCarrier: RemoteRdByteCarrier, @unchecked Sendable {
        private let sent = Mutex<[Data]>([])
        var frames: [Data] { sent.withLock { $0 } }
        func start(queue: DispatchQueue, events: @escaping @Sendable (RemoteRdCarrierEvent) -> Void) {
            queue.async { events(.ready) }
        }
        func send(_ bytes: Data) { sent.withLock { $0.append(bytes) } }
        func cancel() {}
    }

    private static func transport(_ carrier: any RemoteRdByteCarrier) -> RemoteRdStreamTransport? {
        RemoteRdStreamTransport(carrier: carrier, hello: RemoteRdHello.cloudDesktop(install: "test"), startKey: "k", control: false)
    }

    @Test func aDesktopThatDoesNotOpenEndsOnce() async {
        var ends = 0
        let carrier = RemoteRdStreamCarrier(open: { throw NoLink() })
        let stop = CloudDesktopFrames.view(open: { Self.transport(carrier) }, frame: { _ in }, ended: { ends += 1 })
        let deadline = ContinuousClock.now + .seconds(5)
        while ends == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(ends == 1)
        stop()
        #expect(ends == 1)
    }

    @Test func anUnreachableDesktopEndsAfterStartReturns() async {
        var ends = 0
        _ = CloudDesktopFrames.view(open: { nil }, frame: { _ in }, ended: { ends += 1 })
        #expect(ends == 0, "never from inside start: the caller has not kept its stop yet")
        for _ in 0..<1000 where ends == 0 { await Task.yield() }
        #expect(ends == 1)
    }

    @Test func theSessionAsksForViewModeAndAStopNeverReportsAnEnd() async throws {
        var ends = 0
        let carrier = RecordingCarrier()
        let stop = CloudDesktopFrames.view(open: { Self.transport(carrier) }, frame: { _ in }, ended: { ends += 1 })
        let deadline = ContinuousClock.now + .seconds(5)
        while Self.modes(carrier.frames).isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(Self.modes(carrier.frames) == ["view"])
        stop()
        for _ in 0..<200 { await Task.yield() }
        #expect(ends == 0)
    }

    /// The `mode` of each recorded start control (`u8 type, u32 len` stream frames).
    private static func modes(_ frames: [Data]) -> [String] {
        frames.compactMap { frame in
            guard frame.count > 5, let json = (try? JSONSerialization.jsonObject(with: frame.dropFirst(5))) as? [String: Any],
                  json["t"] as? String == "start" else { return nil }
            return json["mode"] as? String
        }
    }
}
