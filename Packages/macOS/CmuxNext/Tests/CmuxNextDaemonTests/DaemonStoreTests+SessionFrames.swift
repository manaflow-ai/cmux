import CmuxNextCompat
@testable import CmuxNextDaemon
import Foundation
import Testing

/// p05-ipc-145: a `session.events` stream opened on a client stream id. Its items come as EVENT frames on
/// that id, which the reader routes by header alone, so an item reaches the store with no envelope scan or
/// decode; its `stream_end` line frees the id, as an attach stream's end does.
extension DaemonStoreTests {
    /// Every event the transport routed: its name, its line or payload, and its index.
    final class RoutedLines: Sendable {
        let lines = Mutex<[(name: String, line: Data, index: UInt64)]>([])
        /// One element per routed event.
        let arrivals: AsyncStream<Void>
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
    }

    /// An EVENT frame on `stream`: the 16-byte header (magic, kind 3, stream, length, aux = the item's
    /// sequence), then `payload`.
    private static func eventFrame(stream: UInt16, sequence: UInt64, payload: String) -> [UInt8] {
        let body = Array(payload.utf8)
        let length = UInt32(body.count)
        var bytes: [UInt8] = [0xFF, LineTransport.eventFrameKind, UInt8(stream & 0xFF), UInt8(stream >> 8)]
        bytes += (0 ..< 4).map { UInt8(truncatingIfNeeded: length >> (8 * $0)) }
        bytes += (0 ..< 8).map { UInt8(truncatingIfNeeded: sequence >> (8 * $0)) }
        return bytes + body
    }

    /// `text` and its newline.
    private static func line(_ text: String) -> [UInt8] { Array(text.utf8) + [0x0A] }

    /// The transport alone: the framed item reaches `onEvent` with no envelope decode, while the same item
    /// as a line the byte scan gives up on costs one; the `stream_end` line frees the id, and a frame on the
    /// freed id is a bad message.
    @Test func aFramedSessionEventsItemIsRoutedByItsHeaderWithNoEnvelopeDecode() async throws {
        let daemon = try ReplyEventOrderTests.FakeDaemon()
        let stats = DaemonWireStats()
        let transport = try LineTransport(path: daemon.path, role: .control, stats: stats)
        try daemon.accept()
        transport.acceptFrames()
        let routed = RoutedLines()
        var arrivals = routed.arrivals.makeAsyncIterator()
        let (closes, closed) = AsyncStream<TransportCloseReason>.makeStream()
        var closeReasons = closes.makeAsyncIterator()
        transport.start(onEvent: { name, line, index in routed.record(name, line, index) },
                        onClose: { reason in _ = closed.yield(reason) })
        defer { transport.close() }
        let session = "stream_\(String(repeating: "e", count: 32))"
        let stream = try #require(transport.routeOnControlSequence(streamID: session, mintingFrameStream: true))
        #expect(stream == 1)

        let item = #"{"type":"stream_item","stream_id":"\#(session)","sequence":"0","item":{"kind":"delta","changes":[]}}"#
        daemon.write(bytes: Self.eventFrame(stream: stream, sequence: 0, payload: item))
        _ = await arrivals.next()
        let first = routed.lines.withLock { $0.first }
        let framed = try #require(first)
        #expect(framed.name == LineTransport.streamEvent && framed.index == 1)
        #expect(framed.line == Data(item.utf8), "the payload reaches onEvent as the stream line it carries")
        #expect(stats.snapshot().jsonDecodes == 0, "the reader scanned or decoded the framed item's envelope")
        #expect(SessionStreamItem.decode(framed.line) == .delta([]))

        // A top-level key written with an escape (`\u0078` is `x`): the byte scan gives this line up, so the
        // reader decodes its envelope, the one decode the frame above never costs.
        let escaped = #"{"type":"stream_item","stream_id":"\#(session)","sequence":"1","\u0078":1,"item":{"kind":"delta","changes":[]}}"#
        #expect(LineRouteScan(Array(escaped.utf8)) == nil, "the scan read the escaped line")
        daemon.write([escaped])
        _ = await arrivals.next()
        #expect(stats.snapshot().jsonDecodes == 1, "the escaped line was not routed by its decoded envelope")

        // The stream_end line ends the stream and frees its id.
        daemon.write([#"{"type":"stream_end","stream_id":"\#(session)","stream":1,"reason":"canceled"}"#])
        _ = await arrivals.next()
        let held = transport.state.withLock { ($0.frameStreams.holds(stream), $0.controlFrameStreams.isEmpty, $0.controlStreams.contains(session)) }
        #expect(!held.0 && held.1 && !held.2, "the stream's end left its client stream id held")
        let indices = routed.lines.withLock { $0.map(\.index) }
        #expect(indices == [1, 2, 3])

        // The daemon writes a stream's items before its end: a frame on the freed id closes the connection.
        daemon.write(bytes: Self.eventFrame(stream: stream, sequence: 2, payload: item))
        let reason = await closeReasons.next()
        #expect(reason == .lost("bad message: event frame on stream 1, which no open stream holds"))
        #expect(transport.routedEventCount == 3, "a frame after the stream's end was counted")
    }

    @Test func aFailedOpenFreesItsClientStreamID() throws {
        let daemon = try ReplyEventOrderTests.FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil)
        try daemon.accept()
        defer { transport.close() }
        let session = "stream_\(String(repeating: "d", count: 32))"
        let stream = try #require(transport.routeOnControlSequence(streamID: session, mintingFrameStream: true))
        transport.endControlSequence(streamID: session)
        let held = transport.state.withLock { ($0.controlStreams.contains(session), $0.controlFrameStreams[stream], $0.frameStreams.holds(stream)) }
        #expect(held.0 == false && held.1 == nil, "the failed open still routes its stream")
        #expect(held.2 == false, "the id is still held")
    }

    // MARK: - Through DaemonConnection

    /// A daemon that serves state resources and grants frames and client streams.
    private static func grantingDaemon() throws -> WireDaemon {
        try WireDaemon(DaemonHandshakeTests.daemon(offers: [DaemonHandshakeTests.frames, DaemonHandshakeTests.streams,
                                                            DaemonCapability.stateResources.rawValue]))
    }

    /// A connection that mirrors the state resources and asks for frames and streams.
    private static func sessionConnection(_ daemon: WireDaemon, stats: DaemonWireStats) -> DaemonConnection {
        var configuration = DaemonHandshakeTests.configuration(upgrades: DaemonHandshakeTests.upgrades, hello: false)
        configuration.sessionEvents = true
        return DaemonConnection(endpoint: DaemonEndpoint(socketPath: daemon.path, wireStats: stats), configuration: configuration)
    }

    /// With streams and frames granted, `openSessionEvents` takes a client stream id and names it in the
    /// open; the snapshot the daemon writes as an EVENT frame on it reaches the store with no envelope
    /// decode (its payload's own decode is the only one), and the `stream_end` frees the id.
    @Test func aGrantedSessionEventsStreamTakesAClientStreamAndItsFramesReachTheStore() async throws {
        let daemon = try Self.grantingDaemon()
        defer { daemon.stop() }
        var opens = daemon.sessionOpens.makeAsyncIterator()
        let stats = DaemonWireStats()
        let connection = Self.sessionConnection(daemon, stats: stats)
        try await connection.start()
        var events = connection.events.makeAsyncIterator()
        let ready = await connection.ready
        let transport = try #require(ready?.transport)
        let grants = transport.wireGrants
        #expect(grants == DaemonWireGrants(frames: true, streams: true))

        let opened = await opens.next()
        let open = try #require(opened, "the connection never opened session.events")
        let stream = try #require(open.stream, "the open named no client stream")
        #expect(stream == 1)
        let mapped = transport.state.withLock { $0.controlFrameStreams[stream] }
        #expect(mapped == open.streamID, "the client stream id does not map to the open's stream")

        // The daemon holds the open unanswered: nothing but the item is decoded while it is routed.
        let before = stats.snapshot().jsonDecodes
        let snapshot = #"{"type":"stream_item","stream_id":"\#(open.streamID)","sequence":"0","item":{"kind":"snapshot","snapshot":{"tabs":[{"id":"tab_1","extra":{"zoom":2}}],"extra":{"state":{}}}}}"#
        #expect(daemon.send(Self.eventFrame(stream: stream, sequence: 0, payload: snapshot), connection: open.connection))
        var item: DaemonEvent?
        while item == nil, let envelope = try await events.next() {
            if case .sessionState(.snapshot) = envelope.event { item = envelope.event }
        }
        let event = try #require(item, "the framed snapshot never reached the connection's events")
        #expect(stats.snapshot().jsonDecodes - before == 1, "the item cost more than its payload's decode: its envelope was decoded")
        let store = DaemonStore()
        store.apply(event)
        #expect(store.session.known && store.session.mirror != nil, "the framed snapshot did not reach the store")

        // The daemon answers the open, then ends the stream: reading its stream_end frees the id.
        let reply = #"{"protocol":"cmux.protocol/2","type":"response","id":"\#(open.requestID)","ok":true,"result":{"stream_id":"\#(open.streamID)"}}"#
        let end = #"{"type":"stream_end","stream_id":"\#(open.streamID)","stream":\#(stream),"reason":"canceled"}"#
        #expect(daemon.send(Self.line(reply) + Self.line(end), connection: open.connection))
        var ended = false
        while !ended, let envelope = try await events.next() {
            if case .sessionState(.ended(reason: "canceled")) = envelope.event { ended = true }
        }
        #expect(ended, "the stream's end never reached the connection's events")
        let held = transport.state.withLock { ($0.frameStreams.holds(stream), $0.controlFrameStreams.isEmpty, $0.controlStreams.contains(open.streamID)) }
        #expect(!held.0 && held.1 && !held.2, "the stream's end left its client stream id held")
        await connection.close()
    }

    /// A refused open frees the client stream id it took, and the store stops waiting for a snapshot.
    @Test func aRefusedSessionEventsOpenFreesItsClientStream() async throws {
        let daemon = try Self.grantingDaemon()
        defer { daemon.stop() }
        var opens = daemon.sessionOpens.makeAsyncIterator()
        let connection = Self.sessionConnection(daemon, stats: DaemonWireStats())
        try await connection.start()
        var events = connection.events.makeAsyncIterator()
        let ready = await connection.ready
        let transport = try #require(ready?.transport)
        let opened = await opens.next()
        let open = try #require(opened, "the connection never opened session.events")
        let stream = try #require(open.stream, "the open named no client stream")
        let taken = transport.state.withLock { $0.frameStreams.holds(stream) }
        #expect(taken, "the open's client stream id is not held")

        let refusal = #"{"protocol":"cmux.protocol/2","type":"response","id":"\#(open.requestID)","ok":false,"error":{"code":"stream_in_use","message":"stream in use"}}"#
        #expect(daemon.send(Self.line(refusal), connection: open.connection))
        var failed = false
        while !failed, let envelope = try await events.next() {
            if case .sessionState(.ended(reason: "failed")) = envelope.event { failed = true }
        }
        #expect(failed, "the refused open never ended the session stream")
        let held = transport.state.withLock { ($0.frameStreams.holds(stream), $0.controlFrameStreams.isEmpty, $0.controlStreams.contains(open.streamID)) }
        #expect(!held.0 && held.1 && !held.2, "the refused open left its client stream id held")
        await connection.close()
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
