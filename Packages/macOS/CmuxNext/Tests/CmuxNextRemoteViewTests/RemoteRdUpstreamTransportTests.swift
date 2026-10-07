import Foundation
import Testing
@testable import CmuxNextRemoteView

/// C4b through the in-app transport against a fake host: the viewer opens
/// an upstream stream only for a granted request to a host whose welcome
/// offers `up_media`, the host's answers drive the status the indicator
/// reads, and stop and the session's end close the stream.
@Suite(.serialized)
struct RemoteRdUpstreamTransportTests {
    typealias Frames = AsyncStream<(UInt8, Data)>.Iterator
    typealias Statuses = AsyncStream<RemoteViewStatus>.Iterator

    /// One viewer session against a fake host. The tests own the iterators
    /// as locals (like `RemoteRdStreamTransportTests`).
    struct Session {
        let host: FakeRdHost
        let transport: RemoteRdStreamTransport
    }

    /// The next control message from the viewer (skips datagrams).
    static func nextControl(_ frames: inout Frames) async throws -> RemoteRdControl {
        while let frame = await frames.next() {
            if frame.0 == 1 { return try RemoteRdControl.parse(frame.1) }
        }
        throw RemoteRdCoreError.failed
    }

    /// Statuses until `done` holds; nil when the stream finished first.
    static func status(_ statuses: inout Statuses, where done: (RemoteViewStatus) -> Bool) async -> RemoteViewStatus? {
        while let status = await statuses.next() {
            if done(status) { return status }
        }
        return nil
    }

    static func start(caps: [String]) async throws -> (Session, Frames, Statuses) {
        let host = try FakeRdHost()
        let port = try await host.start()
        let endpoint = try #require(RemoteRdLoopbackEndpoint(port: port))
        let transport = try #require(RemoteRdStreamTransport(
            endpoint: endpoint,
            hello: RemoteRdHello(user: "u", install: "i", token: nil, caps: ["stream.open", "up_media"]),
            startKey: "display:0", control: true
        ))
        var frames = host.frames.makeAsyncIterator()
        let statuses = transport.statusUpdates().makeAsyncIterator()
        transport.connect()
        _ = try await nextControl(&frames) // hello
        _ = try await nextControl(&frames) // start
        let capsJSON = caps.map { "\"\($0)\"" }.joined(separator: ",")
        host.sendControl(#"{"t":"welcome","encoder":"x264","width":64,"height":64,"max_datagram":1152,"carrier":"stream","service":"desktop","caps":[\#(capsJSON)]}"#)
        host.sendControl(#"{"t":"started","session":1}"#)
        return (Session(host: host, transport: transport), frames, statuses)
    }

    @Test func aGrantedRequestOpensTheStreamAndStopClosesIt() async throws {
        let starteds = try await Self.start(caps: ["stream.open", "up_media"])
        let s = starteds.0
        var f = starteds.1
        var st = starteds.2
        defer { s.host.stop() }
        let offered = await Self.status(&st) { $0.state == .streaming && $0.upstream.offered }
        #expect(offered != nil)

        s.transport.requestUpstream(.microphone, permissionGranted: true)
        #expect(try await Self.nextControl(&f) == .streamOpen(RemoteRdStreamOpen(stream: 100, kind: .upAudio, codec: "opus")))
        #expect(await Self.status(&st) { $0.upstream.requested == [.microphone] } != nil)

        s.host.sendControl(#"{"t":"stream_opened","stream":100}"#)
        let active = await Self.status(&st) { $0.upstream.active == [.microphone] }
        #expect(active?.upstream.requested.isEmpty == true)

        s.transport.stopUpstream(.microphone)
        #expect(try await Self.nextControl(&f) == .streamClose(stream: 100))
        #expect(await Self.status(&st) { $0.upstream.active.isEmpty } != nil)
    }

    @Test func aDeniedPermissionOrAHostWithoutUpMediaOpensNothing() async throws {
        let starteds = try await Self.start(caps: ["stream.open"])
        let s = starteds.0
        var f = starteds.1
        var st = starteds.2
        defer { s.host.stop() }
        let status = await Self.status(&st) { $0.state == .streaming }
        #expect(status?.upstream.offered == false)
        s.transport.requestUpstream(.camera, permissionGranted: true)
        s.transport.requestUpstream(.camera, permissionGranted: false)
        // The viewer's stop is the next control message: no stream_open went out.
        s.transport.stop()
        #expect(try await Self.nextControl(&f) == .stop)

        let startedgranted = try await Self.start(caps: ["stream.open", "up_media"])
        let granted = startedgranted.0
        var gf = startedgranted.1
        var gst = startedgranted.2
        defer { granted.host.stop() }
        _ = await Self.status(&gst) { $0.state == .streaming && $0.upstream.offered }
        granted.transport.requestUpstream(.camera, permissionGranted: false)
        granted.transport.stop()
        #expect(try await Self.nextControl(&gf) == .stop)
    }

    @Test func refusalsAndTheHostsCloseRevokeAndTheViewersStopClosesFirst() async throws {
        let starteds = try await Self.start(caps: ["stream.open", "up_media"])
        let s = starteds.0
        var f = starteds.1
        var st = starteds.2
        defer { s.host.stop() }
        _ = await Self.status(&st) { $0.state == .streaming && $0.upstream.offered }
        s.transport.requestUpstream(.screen, permissionGranted: true)
        #expect(try await Self.nextControl(&f) == .streamOpen(RemoteRdStreamOpen(stream: 100, kind: .upVideo, codec: "h264")))
        s.host.sendControl(#"{"t":"stream_refused","stream":100,"reason":"unsupported"}"#)
        #expect(await Self.status(&st) { $0.upstream.requested.isEmpty && $0.upstream.active.isEmpty } != nil)

        s.transport.requestUpstream(.camera, permissionGranted: true)
        #expect(try await Self.nextControl(&f) == .streamOpen(RemoteRdStreamOpen(stream: 101, kind: .upVideo, codec: "h264")))
        s.host.sendControl(#"{"t":"stream_opened","stream":101}"#)
        #expect(await Self.status(&st) { $0.upstream.active == [.camera] } != nil)
        s.host.sendControl(#"{"t":"stream_close","stream":101}"#)
        #expect(await Self.status(&st) { $0.upstream.active.isEmpty } != nil)

        s.transport.requestUpstream(.microphone, permissionGranted: true)
        #expect(try await Self.nextControl(&f) == .streamOpen(RemoteRdStreamOpen(stream: 102, kind: .upAudio, codec: "opus")))
        s.host.sendControl(#"{"t":"stream_opened","stream":102}"#)
        #expect(await Self.status(&st) { $0.upstream.active == [.microphone] } != nil)
        // The viewer's Stop closes the upstream before the session.
        s.transport.stop()
        #expect(try await Self.nextControl(&f) == .streamClose(stream: 102))
        #expect(try await Self.nextControl(&f) == .stop)
        s.host.sendControl(#"{"t":"ended","reason":"stop"}"#)
        let end = await Self.status(&st) { if case .ended = $0.state { true } else { false } }
        #expect(end?.upstream == RemoteUpstreamStatus())
    }
}
