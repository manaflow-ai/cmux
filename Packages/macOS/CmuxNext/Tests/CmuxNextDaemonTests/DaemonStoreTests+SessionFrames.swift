import CmuxNextCompat
@testable import CmuxNextDaemon
import Foundation
import Testing

/// p05-ipc-145: a `session.events` stream opened on a client stream id. Its items come as EVENT frames on
/// that id, which the reader routes by header alone, so an item reaches the store's event stream with no
/// envelope scan or decode; its `stream_end` line frees the id, as an attach stream's end does.
extension DaemonStoreTests {
    /// Every event the transport routed: its name, its line or payload, and its index.
    final class RoutedLines: Sendable {
        let lines = Mutex<[(name: String, line: Data, index: UInt64)]>([])
        private let arrivals: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            let (arrivals, continuation) = AsyncStream<Void>.makeStream()
            self.arrivals = arrivals
            self.continuation = continuation
        }

        func record(_ name: String, _ line: Data, _ index: UInt64) {
            lines.withLock { $0.append((name, line, index)) }
            continuation.yield()
        }

        /// Returns once `count` more events arrived.
        func waitFor(_ count: Int) async {
            var seen = 0
            for await _ in arrivals {
                seen += 1
                if seen == count { return }
            }
        }
    }

    /// An EVENT frame on `stream`: the 16-byte header (magic, kind 3, stream, length, aux 0), then `payload`.
    private static func eventFrame(stream: UInt16, payload: String) -> [UInt8] {
        let body = Array(payload.utf8)
        let length = UInt32(body.count)
        var bytes: [UInt8] = [0xFF, LineTransport.eventFrameKind, UInt8(stream & 0xFF), UInt8(stream >> 8)]
        bytes += (0 ..< 4).map { UInt8(truncatingIfNeeded: length >> (8 * $0)) }
        bytes += [UInt8](repeating: 0, count: 8)
        return bytes + body
    }

    @Test func aFramedSessionEventsItemReachesTheStoreWithNoEnvelopeDecode() async throws {
        let daemon = try ReplyEventOrderTests.FakeDaemon()
        let stats = DaemonWireStats()
        let transport = try LineTransport(path: daemon.path, role: .control, stats: stats)
        try daemon.accept()
        transport.negotiateFrames()
        let routed = RoutedLines()
        transport.start(onEvent: { name, line, index in routed.record(name, line, index) }, onClose: { _ in })
        defer { transport.close() }
        let session = "stream_\(String(repeating: "e", count: 32))"
        let stream = try #require(transport.routeOnControlSequence(streamID: session, mintingFrameStream: true))
        #expect(stream == 1)

        // An escaped top-level key: the line form of this item costs the reader one envelope decode.
        let item = #"{"type":"stream_item","stream_id":"\#(session)","sequence":"0","x":1,"item":{"kind":"delta","changes":[]}}"#
        daemon.write(bytes: Self.eventFrame(stream: stream, payload: item))
        await routed.waitFor(1)
        let framed = try #require(routed.lines.withLock { $0.first })
        #expect(framed.name == LineTransport.streamEvent && framed.index == 1)
        #expect(framed.line == Data(item.utf8), "the payload reaches onEvent as the stream line it carries")
        #expect(stats.snapshot().jsonDecodes == 0, "the reader decoded the framed item's envelope")
        #expect(SessionStreamItem.decode(framed.line) == .delta([]))

        daemon.write([item])
        await routed.waitFor(1)
        #expect(stats.snapshot().jsonDecodes == 1, "the same item as a line is routed by its envelope")

        // The stream_end line ends the stream and frees its id: a later frame on the id is dropped.
        daemon.write([#"{"type":"stream_end","stream_id":"\#(session)","stream":1,"reason":"canceled"}"#])
        daemon.write(bytes: Self.eventFrame(stream: stream, payload: item))
        daemon.write([#"{"event":"sentinel"}"#])
        await routed.waitFor(2)
        let lines = routed.lines.withLock { $0 }
        #expect(lines.map(\.index) == [1, 2, 3, 4])
        #expect(lines.map(\.name) == [LineTransport.streamEvent, LineTransport.streamEvent, LineTransport.streamEvent, "sentinel"])
        #expect(transport.routedEventCount == 4, "a frame after the stream's end was counted")
    }

    @Test func aFailedOpenFreesItsClientStreamID() throws {
        let daemon = try ReplyEventOrderTests.FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil)
        try daemon.accept()
        defer { transport.close() }
        let session = "stream_\(String(repeating: "d", count: 32))"
        let stream = try #require(transport.routeOnControlSequence(streamID: session, mintingFrameStream: true))
        transport.endControlSequence(streamID: session)
        let held = transport.state.withLock { ($0.controlStreams.contains(session), $0.controlFrameStreams[stream]) }
        #expect(held.0 == false && held.1 == nil, "the failed open still routes its stream")
        #expect(transport.state.withLock { $0.frameStreams.release(stream) } == false, "the id is still held")
    }

    @Test func clientStreamIDsAreTakenRoundRobinAndNeverZero() {
        var ids = FrameStreamIDs()
        let first = ids.mint(), second = ids.mint()
        #expect(first == 1 && second == 2)
        let freed = ids.release(1)
        let third = ids.mint()
        let freedTwice = ids.release(1)
        #expect(freed && !freedTwice, "an id is freed once")
        #expect(third == 3, "an id just freed is not taken again at once")
        var full = FrameStreamIDs()
        for _ in 0 ..< FrameStreamIDs.capacity { _ = full.mint() }
        let past = full.mint()
        #expect(past == nil, "every id is held")
        let seventh = full.release(7)
        let reused = full.mint()
        #expect(seventh && reused == 7)
    }

    @Test func theOpenNamesItsClientStreamOnlyWhenOneWasTaken() {
        let id = "stream_\(String(repeating: "c", count: 32))"
        #expect(SessionEventsWire.params(streamID: id, frameStream: nil) == ["stream_id": .string(id)])
        #expect(SessionEventsWire.params(streamID: id, frameStream: 9) == ["stream_id": .string(id), "stream": .number(9)])
    }
}
