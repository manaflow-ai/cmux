import CmuxRTCSignal
import Foundation
import Testing

/// An in-memory socket: the test plays the server.
private final class FakeSocket: RTCSignalingSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var sentFrames: [String] = []
    private var inbound: [String] = []
    private var receivers: [CheckedContinuation<String, Error>] = []
    private var sendWaiters: [CheckedContinuation<String, Never>] = []
    private var code: Int?
    let protocols: [String]

    init(protocols: [String]) { self.protocols = protocols }

    func send(_ text: String) async throws { deliverSent(text) }

    private func deliverSent(_ text: String) {
        let waiter: CheckedContinuation<String, Never>? = lock.withLock {
            if sendWaiters.isEmpty {
                sentFrames.append(text)
                return nil
            }
            return sendWaiters.removeFirst()
        }
        waiter?.resume(returning: text)
    }

    /// The next frame the client sent.
    func nextSent() async -> String {
        await withCheckedContinuation { c in
            lock.lock()
            if !sentFrames.isEmpty {
                let text = sentFrames.removeFirst()
                lock.unlock()
                c.resume(returning: text)
            } else {
                sendWaiters.append(c)
                lock.unlock()
            }
        }
    }

    func push(_ text: String) {
        lock.lock()
        if let r = receivers.first {
            receivers.removeFirst()
            lock.unlock()
            r.resume(returning: text)
        } else {
            inbound.append(text)
            lock.unlock()
        }
    }

    func serverClose(code: Int) {
        lock.lock()
        self.code = code
        let pending = receivers
        receivers.removeAll()
        lock.unlock()
        for r in pending { r.resume(throwing: URLError(.networkConnectionLost)) }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if !inbound.isEmpty {
                let text = inbound.removeFirst()
                lock.unlock()
                c.resume(returning: text)
            } else if code != nil {
                lock.unlock()
                c.resume(throwing: URLError(.networkConnectionLost))
            } else {
                receivers.append(c)
                lock.unlock()
            }
        }
    }

    func ping() async throws {}
    func close() {}
    var closeCode: Int? {
        lock.lock()
        defer { lock.unlock() }
        return code
    }
}

private final class FakeTransport: RTCSignalingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [FakeSocket] = []
    private var waiters: [CheckedContinuation<FakeSocket, Never>] = []

    func open(url: URL, protocols: [String]) async throws -> any RTCSignalingSocket {
        #expect(url.absoluteString == "wss://api.test/v1/wire/user")
        let socket = FakeSocket(protocols: protocols)
        hand(socket)
        return socket
    }

    private func hand(_ socket: FakeSocket) {
        let waiter: CheckedContinuation<FakeSocket, Never>? = lock.withLock {
            if waiters.isEmpty {
                opened.append(socket)
                return nil
            }
            return waiters.removeFirst()
        }
        waiter?.resume(returning: socket)
    }

    func nextSocket() async -> FakeSocket {
        await withCheckedContinuation { c in
            lock.lock()
            if !opened.isEmpty {
                let s = opened.removeFirst()
                lock.unlock()
                c.resume(returning: s)
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }
}

private final class Tokens: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var forced: [Bool] = []
    func next(_ force: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        forced.append(force)
        return "tok\(forced.count)"
    }
}

/// A clock whose sleeps end at once, so reconnect backoff does not slow the test.
private struct ImmediateClock: Clock {
    typealias Duration = Swift.Duration
    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }
    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Swift.Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        try Task.checkCancellation()
        await Task.yield()
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SignalingClientTests {
    @Test func codecRoundTripsTheBackendFrames() throws {
        let hello = RTCHello(role: .client, peer: "phone-0001", name: "iPhone", tag: "rtc", platform: "ios", appVersion: "1.0")
        let encoded = try #require(try JSONSerialization.jsonObject(with: Data(RTCFrameCodec.encode(hello).utf8)) as? [String: String])
        #expect(encoded == ["t": "rtc.hello", "role": "client", "peer": "phone-0001", "name": "iPhone", "tag": "rtc", "platform": "ios", "app_version": "1.0"])

        let hosts = RTCFrameCodec.decode(#"{"t":"rtc.hosts","hosts":[{"peer":"host-1-abcd","name":"Studio","tag":"rtc","platform":"macos","app_version":"0.1","since":5}]}"#)
        #expect(hosts == .hosts([RTCHostInfo(peer: "host-1-abcd", name: "Studio", tag: "rtc", platform: "macos", appVersion: "0.1", since: 5)]))

        let signal = RTCFrameCodec.decode(#"{"t":"rtc.signal","from":"host-1-abcd","from_role":"host","session":"s1234567","kind":"candidate","candidate":"c","sdp_mid":"0","sdp_mline_index":0}"#)
        #expect(signal == .signal(RTCSignalMessage(peer: "host-1-abcd", peerRole: .host, session: "s1234567", kind: .candidate, candidate: "c", sdpMid: "0", sdpMLineIndex: 0)))
        #expect(RTCFrameCodec.decode(#"{"t":"welcome","principal":{}}"#) == nil)

        let out = try #require(try JSONSerialization.jsonObject(with: Data(RTCFrameCodec.encode(RTCSignalMessage(peer: "host-1-abcd", session: "s1234567", kind: .offer, sdp: "v=0")).utf8)) as? [String: String])
        #expect(out == ["t": "rtc.signal", "to": "host-1-abcd", "session": "s1234567", "kind": "offer", "sdp": "v=0"])
    }

    @Test func helloOnEveryConnectAndAFreshTokenAfterExpiry() async throws {
        let transport = FakeTransport()
        let tokens = Tokens()
        let client = SignalingClient(
            baseURL: URL(string: "https://api.test")!,
            hello: RTCHello(role: .host, peer: "host-1-abcd", name: "Studio", tag: "rtc", platform: "macos", appVersion: "0.1"),
            token: { force in tokens.next(force) },
            transport: transport,
            clock: ImmediateClock()
        )
        var events = client.events.makeAsyncIterator()
        await client.start()

        let first = await transport.nextSocket()
        #expect(first.protocols == ["cmux.wire.v1", "bearer.tok1"])
        #expect(await first.nextSent().contains(#""t":"rtc.hello""#))
        first.push(#"{"t":"welcome","principal":{}}"#)
        first.push(#"{"t":"rtc.welcome","peer":"host-1-abcd"}"#)
        #expect(await events.next() == .online)
        first.push(#"{"t":"rtc.signal","from":"phone-0001","from_role":"client","session":"s1234567","kind":"offer","sdp":"v=0"}"#)
        #expect(await events.next() == .signal(RTCSignalMessage(peer: "phone-0001", peerRole: .client, session: "s1234567", kind: .offer, sdp: "v=0")))

        first.serverClose(code: 4401)
        guard case .offline = await events.next() else {
            Issue.record("expected offline")
            return
        }
        let second = await transport.nextSocket()
        #expect(second.protocols == ["cmux.wire.v1", "bearer.tok2"])
        #expect(await second.nextSent().contains(#""t":"rtc.hello""#))
        #expect(tokens.forced == [false, true])
        await client.stop()
    }
}
