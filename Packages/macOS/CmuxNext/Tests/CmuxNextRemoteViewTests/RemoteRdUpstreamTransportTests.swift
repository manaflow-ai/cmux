import Foundation
import Synchronization
import Testing
@testable import CmuxNextRemoteView

/// C4b through the in-app transport against a fake host: the viewer opens
/// an upstream stream only for a granted request to a host whose welcome
/// offers `up_media`, the host's answers drive the status the indicator
/// reads, and stop and the session's end close the stream.
@Suite(.serialized)
struct RemoteRdUpstreamTransportTests {
    /// One viewer session against a fake host. Recorders drain the host's
    /// frames and the transport's statuses so the tests read them in order.
    nonisolated final class Session: Sendable {
        let host: FakeRdHost
        let transport: RemoteRdStreamTransport
        let frames: StreamRecorder<(UInt8, Data)>
        let statuses: StreamRecorder<RemoteViewStatus>

        init(host: FakeRdHost, transport: RemoteRdStreamTransport) {
            self.host = host
            self.transport = transport
            frames = StreamRecorder(host.frames)
            statuses = StreamRecorder(transport.statusUpdates())
        }

        /// The next control message from the viewer (skips datagrams).
        func nextControl() async throws -> RemoteRdControl {
            while let frame = await frames.next() {
                if frame.0 == 1 { return try RemoteRdControl.parse(frame.1) }
            }
            throw RemoteRdCoreError.failed
        }

        /// Statuses until `done` holds; nil when the stream finished first.
        func status(where done: (RemoteViewStatus) -> Bool) async -> RemoteViewStatus? {
            while let status = await statuses.next() {
                if done(status) { return status }
            }
            return nil
        }
    }

    static func start(caps: [String]) async throws -> Session {
        let host = try FakeRdHost()
        let port = try await host.start()
        let endpoint = try #require(RemoteRdLoopbackEndpoint(port: port))
        let transport = try #require(RemoteRdStreamTransport(
            endpoint: endpoint,
            hello: RemoteRdHello(user: "u", install: "i", token: nil, caps: ["stream.open", "up_media"]),
            startKey: "display:0", control: true
        ))
        let session = Session(host: host, transport: transport)
        transport.connect()
        _ = try await session.nextControl() // hello
        _ = try await session.nextControl() // start
        let capsJSON = caps.map { "\"\($0)\"" }.joined(separator: ",")
        host.sendControl(#"{"t":"welcome","encoder":"x264","width":64,"height":64,"max_datagram":1152,"carrier":"stream","service":"desktop","caps":[\#(capsJSON)]}"#)
        host.sendControl(#"{"t":"started","session":1}"#)
        return session
    }

    @Test func aGrantedRequestOpensTheStreamAndStopClosesIt() async throws {
        let s = try await Self.start(caps: ["stream.open", "up_media"])
        defer { s.host.stop() }
        let offered = await s.status { $0.state == .streaming && $0.upstream.offered }
        #expect(offered != nil)

        s.transport.requestUpstream(.microphone, permissionGranted: true)
        #expect(try await s.nextControl() == .streamOpen(RemoteRdStreamOpen(stream: 100, kind: .upAudio, codec: "opus")))
        #expect(await s.status { $0.upstream.requested == [.microphone] } != nil)

        s.host.sendControl(#"{"t":"stream_opened","stream":100}"#)
        let active = await s.status { $0.upstream.active == [.microphone] }
        #expect(active?.upstream.requested.isEmpty == true)

        s.transport.stopUpstream(.microphone)
        #expect(try await s.nextControl() == .streamClose(stream: 100))
        #expect(await s.status { $0.upstream.active.isEmpty } != nil)
    }

    @Test func aDeniedPermissionOrAHostWithoutUpMediaOpensNothing() async throws {
        let s = try await Self.start(caps: ["stream.open"])
        defer { s.host.stop() }
        let status = await s.status { $0.state == .streaming }
        #expect(status?.upstream.offered == false)
        s.transport.requestUpstream(.camera, permissionGranted: true)
        s.transport.requestUpstream(.camera, permissionGranted: false)
        // The viewer's stop is the next control message: no stream_open went out.
        s.transport.stop()
        #expect(try await s.nextControl() == .stop)

        let granted = try await Self.start(caps: ["stream.open", "up_media"])
        defer { granted.host.stop() }
        _ = await granted.status { $0.state == .streaming && $0.upstream.offered }
        granted.transport.requestUpstream(.camera, permissionGranted: false)
        granted.transport.stop()
        #expect(try await granted.nextControl() == .stop)
    }

    @Test func refusalsAndTheHostsCloseRevokeAndTheViewersStopClosesFirst() async throws {
        let s = try await Self.start(caps: ["stream.open", "up_media"])
        defer { s.host.stop() }
        _ = await s.status { $0.state == .streaming && $0.upstream.offered }
        s.transport.requestUpstream(.screen, permissionGranted: true)
        #expect(try await s.nextControl() == .streamOpen(RemoteRdStreamOpen(stream: 100, kind: .upVideo, codec: "h264")))
        s.host.sendControl(#"{"t":"stream_refused","stream":100,"reason":"unsupported"}"#)
        #expect(await s.status { $0.upstream.requested.isEmpty && $0.upstream.active.isEmpty } != nil)

        s.transport.requestUpstream(.camera, permissionGranted: true)
        #expect(try await s.nextControl() == .streamOpen(RemoteRdStreamOpen(stream: 101, kind: .upVideo, codec: "h264")))
        s.host.sendControl(#"{"t":"stream_opened","stream":101}"#)
        #expect(await s.status { $0.upstream.active == [.camera] } != nil)
        s.host.sendControl(#"{"t":"stream_close","stream":101}"#)
        #expect(await s.status { $0.upstream.active.isEmpty } != nil)

        s.transport.requestUpstream(.microphone, permissionGranted: true)
        #expect(try await s.nextControl() == .streamOpen(RemoteRdStreamOpen(stream: 102, kind: .upAudio, codec: "opus")))
        s.host.sendControl(#"{"t":"stream_opened","stream":102}"#)
        #expect(await s.status { $0.upstream.active == [.microphone] } != nil)
        // The viewer's Stop closes the upstream before the session.
        s.transport.stop()
        #expect(try await s.nextControl() == .streamClose(stream: 102))
        #expect(try await s.nextControl() == .stop)
        s.host.sendControl(#"{"t":"ended","reason":"stop"}"#)
        let end = await s.status { if case .ended = $0.state { true } else { false } }
        #expect(end?.upstream == RemoteUpstreamStatus())
    }
}

/// Drains an AsyncStream on its own task and hands out its elements in
/// order; `next` waits (bounded, 10 s) for the next one, nil once finished.
nonisolated final class StreamRecorder<Element: Sendable>: Sendable {
    private let state = Mutex<(items: [Element], cursor: Int, finished: Bool)>(([], 0, false))

    init(_ stream: AsyncStream<Element>) {
        Task.detached { [self] in
            for await element in stream {
                self.state.withLock { $0.items.append(element) }
            }
            self.state.withLock { $0.finished = true }
        }
    }

    func next() async -> Element? {
        for _ in 0..<2_000 {
            let result: (Element?, Bool) = state.withLock { state in
                if state.cursor < state.items.count {
                    defer { state.cursor += 1 }
                    return (state.items[state.cursor], true)
                }
                return (nil, state.finished)
            }
            if result.1 { return result.0 }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
}
