import AppKit
import CoreVideo
@testable import CmuxNextApp
@testable import CmuxNextRemoteView
@testable import CmuxNextRemoteViewSessions
import CmuxVNC
import Foundation
import Testing

/// VNC compatibility hosts in the remote view pane (remote-desktop.md 12).
struct RemoteViewVNCRecordTests {
    @Test func vncRecordRoundTrips() throws {
        let record = try #require(RemoteViewTabRecord(host: "cmux10s-mac-mini", mode: .control, vncPort: 5901))
        let parsed = try #require(RemoteViewTabRecord(url: record.url))
        #expect(parsed == record)
        #expect(record.url.absoluteString.contains("via=vnc&port=5901"))
    }

    @Test func vncWithoutPortDefaultsTo5900() throws {
        let record = try #require(RemoteViewTabRecord(url: URL(string: "cmux://remote-view?host=mac.local&via=vnc")))
        #expect(record.vncPort == 5900)
    }

    @Test func rdRecordsAreUnchanged() throws {
        let record = try #require(RemoteViewTabRecord(host: "mock"))
        #expect(record.vncPort == nil)
        #expect(!record.url.absoluteString.contains("via"))
    }

    @Test(arguments: [
        "cmux://remote-view?host=a&via=vnc&port=0",
        "cmux://remote-view?host=a&via=vnc&port=70000",
        "cmux://remote-view?host=a&via=vnc&port=-1",
        "cmux://remote-view?host=a&via=ssh",
        "cmux://remote-view?host=a&port=5900",
        "cmux://remote-view?host=a&via=vnc&via=vnc",
    ])
    func rejectsBadVNCFields(_ raw: String) {
        #expect(RemoteViewTabRecord(url: URL(string: raw)) == nil)
    }
}

struct RemoteViewVNCPolicyTests {
    let policy = RemoteViewTabPolicy()

    @Test(arguments: ["mock", "127.0.0.1", "100.70.231.80", "100.127.0.1", "10.0.0.5", "172.20.21.138", "192.168.1.2",
                      "mini.tail137216.ts.net", "studio.local", "cmux10s-mac-mini"])
    func privateHostsConnect(_ host: String) throws {
        let record = try #require(RemoteViewTabRecord(host: host, vncPort: 5900))
        #expect(policy.decide(record: record, source: .person, paneAvailable: true) == .connect(record))
    }

    @Test(arguments: ["8.8.8.8", "100.128.0.1", "172.32.0.1", "example.com", "203.0.113.4", "134744072", "0x08080808", "8.8.2056"])
    func publicHostsAreRefused(_ host: String) throws {
        let record = try #require(RemoteViewTabRecord(host: host, vncPort: 5900))
        #expect(policy.decide(record: record, source: .person, paneAvailable: true) == .unavailable(.notPrivateNetwork(host: host)))
    }

    @Test func rdStaysLoopbackOnly() throws {
        let record = try #require(RemoteViewTabRecord(host: "10.0.0.5"))
        #expect(policy.decide(record: record, source: .person, paneAvailable: true) == .unavailable(.notLoopback(host: "10.0.0.5")))
    }

    @Test func unconfirmedVNCAsksAndStartsInViewMode() throws {
        let record = try #require(RemoteViewTabRecord(host: "studio.local", mode: .control, vncPort: 5900))
        guard case let .confirm(asked) = policy.decide(record: record, source: .unconfirmed, paneAvailable: true) else {
            Issue.record("expected confirm")
            return
        }
        #expect(asked.mode == .view && asked.vncPort == 5900)
    }

    @Test func remoteTreeVNCRecordsNeverOpen() throws {
        let record = try #require(RemoteViewTabRecord(host: "mock", vncPort: 5900))
        #expect(policy.decide(record: record, source: .remoteTree, paneAvailable: true) == .unavailable(.remoteRecord))
    }
}

struct RemoteViewFitGeometryTests {
    @Test func fitScalesDownAndCenters() {
        let geometry = RemoteViewGeometry(framePixels: CGSize(width: 2000, height: 1000), bounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                                          backingScale: 2, scaling: .fit)
        #expect(geometry.imageRect == CGRect(x: 0, y: 100, width: 400, height: 200))
        let pixel = geometry.streamPixel(at: CGPoint(x: 200, y: 200))
        #expect(pixel?.x == 1000 && pixel?.y == 500)
        #expect(geometry.streamPixel(at: CGPoint(x: 200, y: 50)) == nil)
        let point = geometry.panePoint(forStreamPixel: 1000, 500)
        #expect(point == CGPoint(x: 200, y: 200))
    }

    @Test func fitScalesUp() {
        let geometry = RemoteViewGeometry(framePixels: CGSize(width: 100, height: 100), bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
                                          backingScale: 2, scaling: .fit)
        #expect(geometry.imageRect == CGRect(x: 50, y: 0, width: 200, height: 200))
        #expect(geometry.clampedStreamPixel(at: CGPoint(x: 249, y: 199)) == (99, 99))
    }

    @Test func nativeIsUnchanged() {
        let geometry = RemoteViewGeometry(framePixels: CGSize(width: 800, height: 600), bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
                                          backingScale: 2)
        #expect(geometry.imageRect == CGRect(x: 0, y: 0, width: 400, height: 300))
    }
}

struct RemoteVNCMappingTests {
    @Test func failuresMapToPaneEnds() {
        #expect(RemoteVNCSource.end(for: nil, hadCredentials: false) == .stoppedByViewer)
        #expect(RemoteVNCSource.end(for: .credentialsRequired, hadCredentials: false) == .signInRequired(rejected: false))
        #expect(RemoteVNCSource.end(for: .passwordRequired, hadCredentials: false) == .signInRequired(rejected: false))
        #expect(RemoteVNCSource.end(for: .authenticationFailed("no"), hadCredentials: true) == .signInRequired(rejected: true))
        #expect(RemoteVNCSource.end(for: .transport("refused"), hadCredentials: true) == .connectionLost)
        #expect(RemoteVNCSource.end(for: .connectionClosed, hadCredentials: false) == .connectionLost)
    }

    @Test func scrollAccumulatesToWheelClicks() {
        var scroll = RemoteVNCScroll()
        #expect(scroll.add(dx: 0, dy: 50, precise: false) == (0, 0))
        #expect(scroll.add(dx: 0, dy: 60, precise: false) == (0, 1))
        #expect(scroll.add(dx: -250, dy: 0, precise: false) == (-2, 0))
        #expect(scroll.add(dx: 0, dy: -1500, precise: true) == (0, -1))
    }
}

#if DEBUG
@MainActor
struct RemoteVNCReconnectTests {
    @Test(.timeLimit(.minutes(1))) func manualReconnectCancelsStaleAutomaticRetry() async throws {
        let record = try #require(RemoteViewTabRecord(host: "vm-test", target: .virtual, mode: .view, cloudDesktop: true))
        let attempts = AttemptCounter()
        let session = RemoteVNCSession(cloudRecord: record) {
            attempts.increment()
            return ConnectedRFBTransport()
        }
        defer { session.close() }
        session.scheduleAutomaticRetryForTesting(after: .seconds(30))
        let staleRetry = try #require(session.pendingRetryForTesting)

        let statuses = session.source.statusUpdates()
        session.reconnect(in: nil)
        #expect(!session.hasPendingRetryForTesting)
        for await status in statuses {
            if status.state == .streaming { break }
            if case .ended = status.state { break }
        }
        try #require(session.source.status.state == .streaming)
        let connectedClient = try #require(session.source.client)
        // The RFB handshake succeeded. A stale retry must not replace this connection.
        #expect(attempts.value == 1)
        // The cancelled retry ends without connecting again; awaiting it replaces a sleep past its deadline.
        await staleRetry.value
        #expect(attempts.value == 1)
        #expect(session.source.client === connectedClient)
        #expect(session.source.status.state == .streaming)
    }

    @Test(.timeLimit(.minutes(1))) func queuedLossAfterManualReconnectSchedulesNoRetry() async throws {
        let record = try #require(RemoteViewTabRecord(host: "vm-test", target: .virtual, mode: .view, cloudDesktop: true))
        let attempts = AttemptCounter()
        let session = RemoteVNCSession(cloudRecord: record) {
            attempts.increment()
            return ConnectedRFBTransport()
        }
        defer { session.close() }

        let statuses = session.source.statusUpdates()
        session.reconnect(in: nil)
        for await status in statuses {
            if status.state == .streaming { break }
            if case .ended = status.state { break }
        }
        try #require(session.source.status.state == .streaming)
        let connectedClient = try #require(session.source.client)
        // A loss from the old session, queued on the main actor before the manual reconnect,
        // lands now. It must not schedule a retry that would replace the healthy connection.
        session.deliverQueuedLossForTesting()
        #expect(!session.hasPendingRetryForTesting)
        #expect(attempts.value == 1)
        #expect(session.source.client === connectedClient)
    }

    @Test(.timeLimit(.minutes(1))) func queuedLossAfterStopSchedulesNoRetry() async throws {
        let record = try #require(RemoteViewTabRecord(host: "vm-test", target: .virtual, mode: .view, cloudDesktop: true))
        let transports = TransportBox()
        let session = RemoteVNCSession(cloudRecord: record) {
            let transport = ConnectedRFBTransport()
            transports.add(transport)
            return transport
        }
        defer { session.close() }

        let statuses = session.source.statusUpdates()
        session.reconnect(in: nil)
        for await status in statuses {
            if status.state == .streaming { transports.closeAll() }
            if case .ended = status.state { break }
        }
        guard case .ended(.connectionLost) = session.source.status.state else {
            Issue.record("expected a lost connection, got \(session.source.status.state)")
            return
        }
        // Stop (a hidden tab) lands before the loss queued on the main actor. The loss must not
        // schedule a retry that reconnects the stopped tab.
        session.stop()
        session.deliverQueuedLossForTesting()
        #expect(!session.hasPendingRetryForTesting)
    }
}

/// The input and output fences between `RemoteVNCSource` sessions (#29212).
@MainActor
struct RemoteVNCGenerationTests {
    private static let endpoint = VNCEndpoint(host: "vm-test", port: 5901)

    /// Starts a session on `transport` and returns once it streams.
    private func connect(_ source: RemoteVNCSource, over transport: RecordingRFBTransport) async throws {
        source.connect(to: Self.endpoint, credentials: VNCCredentials(), transport: transport)
        // Subscribed after `connect`, so the first status is this session's, never the last one's.
        for await status in source.statusUpdates() {
            if status.state == .streaming { break }
            if case .ended = status.state { break }
        }
        try #require(source.status.state == .streaming)
    }

    @Test(.timeLimit(.minutes(1))) func inputQueuedForAnOldSessionNeverReachesTheNext() async throws {
        let source = RemoteVNCSource()
        let first = RecordingRFBTransport(holdFirstKey: true)
        let second = RecordingRFBTransport()
        try await connect(source, over: first)
        let sink = RemoteVNCInputSink(source: source)
        var firstKeys = first.keySends.makeAsyncIterator()
        var secondKeys = second.keySends.makeAsyncIterator()

        // The worker holds inside the first session's send; "b" waits in the queue behind it.
        sink.send(.text("a"))
        _ = await firstKeys.next()
        sink.send(.text("b"))
        try await connect(source, over: second)
        first.release()
        sink.send(.text("c"))
        _ = await secondKeys.next()

        // The worker drains in order: "b" was handled before "c", so had it leaked, it would be here.
        #expect(second.keyChunks.map(\.last) == [UInt8(ascii: "c")])
        #expect(first.keyChunks.map(\.last) == [UInt8(ascii: "a")])
    }

    @Test(.timeLimit(.minutes(1))) func oldSessionCannotPublishAfterReconnectOrStop() async throws {
        let source = RemoteVNCSource()
        try await connect(source, over: RecordingRFBTransport())
        let first = source.generationForTesting
        // The same one-element stream is retained across both connections.
        let output = source.decodedFrames()
        try await connect(source, over: RecordingRFBTransport())
        let second = source.generationForTesting
        #expect(second > first)

        var pixels: CVPixelBuffer?
        let created = CVPixelBufferCreate(kCFAllocatorDefault, 1, 1, kCVPixelFormatType_32BGRA, nil, &pixels)
        #expect(created == kCVReturnSuccess)
        let buffer = try #require(pixels)
        func frame(_ number: UInt32) -> RemoteDecodedFrame {
            RemoteDecodedFrame(pixelBuffer: buffer, frame: number, tCaptureMicros: 0, decodedAtNanos: 0)
        }
        source.publishFrameForTesting(frame(42), generation: second)
        // If this stale frame enters bufferingNewest(1), it replaces frame 42.
        source.publishFrameForTesting(frame(13), generation: first)
        source.publishStatusForTesting(RemoteViewStatus(path: .compatibility, state: .ended(.connectionLost)),
                                     generation: first)
        #expect(source.status.state == .streaming)

        source.stop()
        source.publishFrameForTesting(frame(14), generation: second)
        source.publishStatusForTesting(RemoteViewStatus(path: .compatibility, state: .streaming),
                                     generation: second)
        #expect(source.status.state == .ended(.stoppedByViewer))

        var iterator = output.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.frame == 42)
    }

    @Test(.timeLimit(.minutes(1))) func stopEndsTheGenerationAtOnce() async throws {
        let source = RemoteVNCSource()
        try await connect(source, over: RecordingRFBTransport())
        source.stop()
        #expect(source.client == nil)
        // Published by `stop` itself, not by the old session's disconnect arriving later.
        #expect(source.status.state == .ended(.stoppedByViewer))
    }
}

/// An RFB server that accepts the handshake and records what the client sends. With
/// `holdFirstKey`, the first KeyEvent send waits until `release()`.
private nonisolated final class RecordingRFBTransport: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [[UInt8]] = []
    private var holding: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    private let bytes: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    /// One element per KeyEvent message the client sent (after it is recorded and, if held, waiting).
    let keySends: AsyncStream<Void>
    private let keySendsSink: AsyncStream<Void>.Continuation

    init(holdFirstKey: Bool = false) {
        holding = holdFirstKey
        (keySends, keySendsSink) = AsyncStream.makeStream(of: Void.self)
        (bytes, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self)
        var handshake = Array("RFB 003.008\n".utf8)
        handshake += [1, 1, 0, 0, 0, 0] // None security, accepted.
        handshake += [0, 1, 0, 1] // One-pixel desktop.
        handshake += RFBPixelFormat.bgrx.encoded
        handshake += [0, 0, 0, 4] + Array("test".utf8)
        continuation.yield(handshake)
    }

    /// Each KeyEvent send (RFB client message 4), in order.
    var keyChunks: [[UInt8]] { lock.withLock { sent.filter { $0.first == 4 } } }

    func open() async throws {}
    func receive() async throws -> [UInt8] {
        var iterator = bytes.makeAsyncIterator()
        guard let chunk = try await iterator.next() else { throw RFBError.connectionClosed }
        return chunk
    }

    func send(_ bytes: [UInt8]) async throws {
        let isKey = bytes.first == 4
        let hold = lock.withLock { () -> Bool in
            sent.append(bytes)
            guard isKey, holding else { return false }
            holding = false
            return true
        }
        guard isKey else { return }
        guard hold else {
            keySendsSink.yield()
            return
        }
        await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                self.gate = gate
                return false
            }
            keySendsSink.yield()
            if resumeNow { gate.resume() }
        }
    }

    /// Lets a held KeyEvent send finish.
    func release() {
        let gate = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { self.gate = nil }
            return self.gate
        }
        gate?.resume()
    }

    func close() { continuation.finish(throwing: RFBError.connectionClosed) }
}

private nonisolated final class TransportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [ConnectedRFBTransport] = []

    func add(_ transport: ConnectedRFBTransport) { lock.withLock { transports.append(transport) } }
    func closeAll() { lock.withLock { transports }.forEach { $0.close() } }
}

private nonisolated final class ConnectedRFBTransport: RFBTransport {
    private let bytes: AsyncThrowingStream<[UInt8], any Error>
    private let continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation

    init() {
        (bytes, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self)
        var handshake = Array("RFB 003.008\n".utf8)
        handshake += [1, 1, 0, 0, 0, 0] // None security, accepted.
        handshake += [0, 1, 0, 1] // One-pixel desktop.
        handshake += RFBPixelFormat.bgrx.encoded
        handshake += [0, 0, 0, 4] + Array("test".utf8)
        continuation.yield(handshake)
    }

    func open() async throws {}
    func receive() async throws -> [UInt8] {
        var iterator = bytes.makeAsyncIterator()
        guard let chunk = try await iterator.next() else { throw RFBError.connectionClosed }
        return chunk
    }
    func send(_ bytes: [UInt8]) async throws {}
    func close() { continuation.finish(throwing: RFBError.connectionClosed) }
}

private nonisolated final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
#endif
