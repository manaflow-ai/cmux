import Foundation
import Network
import Synchronization
import Testing
@testable import CmuxNextRemoteView

/// A host stand-in on 127.0.0.1 that speaks the stream carrier: it records
/// every frame the viewer sends and sends frames back. Headless: no window.
nonisolated final class FakeRdHost: Sendable {
    let listener: NWListener
    let frames: AsyncStream<(UInt8, Data)>
    private let framesContinuation: AsyncStream<(UInt8, Data)>.Continuation
    private let queue = DispatchQueue(label: "cmux.remote-view.tests.fake-host")
    private let state = Mutex<(connection: NWConnection?, buffer: Data)>((nil, Data()))

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        (frames, framesContinuation) = AsyncStream.makeStream(of: (UInt8, Data).self, bufferingPolicy: .unbounded)
    }

    /// Starts listening and returns the port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            state.withLock { $0.connection = connection }
            connection.start(queue: queue)
            receive(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Mutex(false)
            listener.stateUpdateHandler = { [listener] newState in
                let first = once.withLock { done in defer { done = true }; return !done }
                switch newState {
                case .ready where first: continuation.resume(returning: listener.port?.rawValue ?? 0)
                case let .failed(error) where first: continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        state.withLock { $0.connection?.cancel() }
        framesContinuation.finish()
    }

    static func frame(_ type: UInt8, _ payload: Data) -> Data {
        var out = Data([type])
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    func send(_ bytes: Data) {
        state.withLock { $0.connection }?.send(content: bytes, completion: .idempotent)
    }

    func sendControl(_ json: String) {
        send(Self.frame(1, Data(json.utf8)))
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data {
                let parsed = state.withLock { state -> [(UInt8, Data)] in
                    state.buffer.append(data)
                    var out: [(UInt8, Data)] = []
                    while state.buffer.count >= 5 {
                        let bytes = [UInt8](state.buffer.prefix(5))
                        let len = Int(UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24)
                        guard state.buffer.count >= 5 + len else { break }
                        out.append((bytes[0], Data(state.buffer.dropFirst(5).prefix(len))))
                        state.buffer = Data(state.buffer.dropFirst(5 + len))
                    }
                    return out
                }
                parsed.forEach { framesContinuation.yield($0) }
            }
            if !complete, error == nil { receive(connection) }
        }
    }
}

@Suite(.serialized)
struct RemoteRdStreamTransportTests {
    @Test func aSessionStreamsFramesSendsInputAndEnds() async throws {
        let host = try FakeRdHost()
        defer { host.stop() }
        let port = try await host.start()
        let endpoint = try #require(RemoteRdLoopbackEndpoint(port: port))
        let token = String(repeating: "ab", count: 32)
        let transport = try #require(RemoteRdStreamTransport(
            endpoint: endpoint, hello: RemoteRdHello(user: "u", install: "i", token: token), startKey: "display:0", control: true
        ))
        let units = transport.accessUnits()
        let statuses = transport.statusUpdates()
        var hostFrames = host.frames.makeAsyncIterator()
        transport.connect()

        // Hello, then start, as control frames.
        let hello = try #require(await hostFrames.next())
        #expect(hello.0 == 1)
        let helloJSON = try RemoteRdControlTests.object(hello.1)
        #expect(helloJSON["t"] as? String == "hello")
        #expect(helloJSON["token"] as? String == token)
        #expect(helloJSON["udp_port"] == nil)
        let start = try #require(await hostFrames.next())
        #expect(try RemoteRdControl.parse(start.1) == .start(key: "display:0", mode: "control"))

        // Welcome, started and one keyframe on the stream carrier.
        host.sendControl(#"{"t":"welcome","encoder":"x264","width":64,"height":64,"max_datagram":1152,"carrier":"stream","service":"desktop","caps":[]}"#)
        host.sendControl(#"{"t":"started","session":9}"#)
        let au = RemoteRdCoreTests.annexB(5, 3000)
        for datagram in RemoteRdCoreTests.datagrams(frame: 1, keyframe: true, accessUnit: au, tCapture: 77, shardLen: 1136, firstSeq: 0) {
            host.send(FakeRdHost.frame(2, datagram))
        }
        var unitIterator = units.makeAsyncIterator()
        let unit = try #require(await unitIterator.next())
        #expect(unit.frame == 1)
        #expect(unit.isKeyframe)
        #expect([UInt8](unit.data) == au)

        var statusIterator = statuses.makeAsyncIterator()
        var sawStreaming = false
        while let status = await statusIterator.next() {
            if status.state == .streaming { sawStreaming = true; break }
        }
        #expect(sawStreaming)

        // Input goes out as an Input datagram (kind 4) in a type-2 frame; feedback (kind 7) may come first.
        transport.send(.key(usage: 0x0007_0004, down: true))
        var sawInput = false
        while let frame = await hostFrames.next() {
            if frame.0 == 2, frame.1.count > 16, frame.1[frame.1.startIndex + 1] == 4 { sawInput = true; break }
        }
        #expect(sawInput)

        // The host ends the session: the status ends and the frame stream finishes.
        host.sendControl(#"{"t":"ended","reason":"host stopped"}"#)
        var end: RemoteSessionState?
        while let status = await statusIterator.next() {
            end = status.state
        }
        #expect(end == .ended(.hostStoppedSharing))
        #expect(await unitIterator.next() == nil)
    }

    @Test func aRefusedHelloEndsWithConsentDenied() async throws {
        let host = try FakeRdHost()
        defer { host.stop() }
        let port = try await host.start()
        let endpoint = try #require(RemoteRdLoopbackEndpoint(port: port))
        let transport = try #require(RemoteRdStreamTransport(
            endpoint: endpoint, hello: RemoteRdHello(user: "u", install: "i", token: nil, service: "rb/1"), startKey: "tab"
        ))
        let statuses = transport.statusUpdates()
        var hostFrames = host.frames.makeAsyncIterator()
        transport.connect()
        _ = await hostFrames.next()
        host.sendControl(#"{"t":"refused","reason":"service"}"#)
        var end: RemoteSessionState?
        for await status in statuses {
            end = status.state
        }
        #expect(end == .ended(.consentDenied))
    }

    @Test func privilegedPortsAreRefused() {
        #expect(RemoteRdLoopbackEndpoint(port: 80) == nil)
        #expect(RemoteRdLoopbackEndpoint(port: 4103) != nil)
    }
}
