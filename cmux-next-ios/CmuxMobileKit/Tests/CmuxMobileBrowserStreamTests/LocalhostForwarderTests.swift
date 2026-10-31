import CmuxMobileTransport
import Foundation
import Network
import Testing
@testable import CmuxMobileBrowserStream

/// The Mac's side of one `localhost` channel: a web server on its loopback that
/// answers every request on the connection (keep-alive), or a refusal.
final class FakeLoopbackChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let lock = NSLock()
    private var request = Data()
    private var replies: AsyncStream<Data>.Continuation
    private let stream: AsyncStream<Data>
    private var iterator: AsyncStream<Data>.Iterator?
    private let body: String?
    private let refusal: LinkError?

    /// `body`: what each request gets; nil with `refusal`: the Mac refused the connection.
    init(body: String?, refusal: LinkError? = nil) {
        self.body = body
        self.refusal = refusal
        (stream, replies) = AsyncStream<Data>.makeStream()
        iterator = stream.makeAsyncIterator()
        if refusal != nil { replies.finish() }
    }

    func send(_ data: Data) async throws {
        guard let body else { throw LinkError(code: "closed", message: "closed") }
        let answers: Int = lock.withLock {
            request.append(data)
            var count = 0
            while let end = request.range(of: Data("\r\n\r\n".utf8)) {
                request.removeSubrange(..<end.upperBound)
                count += 1
            }
            return count
        }
        for _ in 0..<answers {
            replies.yield(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
        }
    }

    func receive() async throws -> Data? {
        var next = lock.withLock { iterator }
        let data = await next?.next()
        lock.withLock { iterator = next }
        return data
    }

    func close(code: String, reason: String) async { replies.finish() }

    var closedBy: LinkError? { refusal }
}

/// True the first time only.
final class FirstOnly: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
}

/// What the forwarder asked the link for.
final class OpenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [(macID: String?, port: UInt16)] = []
    func note(_ macID: String?, _ port: UInt16) { lock.withLock { opened.append((macID, port)) } }
    var all: [(macID: String?, port: UInt16)] { lock.withLock { opened } }
}

/// A native browser tab's `localhost:<port>` reaches the Mac's loopback through
/// this iPhone's own listener: the request goes over the link, the reply comes back.
@MainActor @Suite(.serialized) struct LocalhostForwarderTests {
    func fetch(_ port: UInt16, path: String = "/", origin: String? = nil) async -> (status: Int, body: String)? {
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.timeoutInterval = 10
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    /// A free port on this machine's loopback (a forward on a used one says `portInUse`).
    func forwardOnFreePort(_ forwarder: LocalhostForwarder, macID: String?) async throws -> UInt16 {
        for _ in 0..<20 {
            let port = UInt16.random(in: 20000...60000)
            do throws(LocalhostForwarder.Failure) {
                try await forwarder.forward(port: port, macID: macID)
                return port
            } catch .portInUse {
                continue
            }
        }
        Issue.record("no free port")
        throw CancellationError()
    }

    @Test func aRequestToThePhonesLoopbackPortIsServedByTheMacsPort() async throws {
        let log = OpenLog()
        let forwarder = LocalhostForwarder { macID, port in
            log.note(macID, port)
            return FakeLoopbackChannel(body: "served on the Mac's loopback")
        }
        let port = try await forwardOnFreePort(forwarder, macID: "mac-studio")
        #expect(forwarder.ports == [port])

        let first = await fetch(port)
        #expect(forwarder.counts.accepted > 0, "the page's connection reached this iPhone's listener: \(forwarder.counts)")
        #expect(forwarder.counts.refused == 0, "the gate passed it: \(forwarder.counts)")
        #expect(first?.status == 200)
        #expect(first?.body == "served on the Mac's loopback")
        // Another request (the page's script or image) goes the same way.
        #expect(await fetch(port, path: "/data.json")?.body == "served on the Mac's loopback")
        #expect(log.all.allSatisfy { $0.macID == "mac-studio" && $0.port == port })
        #expect(!log.all.isEmpty)
        #expect(forwarder.refusals[port] == nil)

        // No tab shows the port any more: it stops listening.
        forwarder.retain(ports: [])
        #expect(forwarder.ports.isEmpty)
        #expect(await fetch(port) == nil)
    }

    @Test func theMacsRefusalIsKeptForTheCard() async throws {
        let refusal = LinkError(code: "unavailable", message: "Nothing is listening on port 3000 on this Mac.")
        let forwarder = LocalhostForwarder { _, _ in FakeLoopbackChannel(body: nil, refusal: refusal) }
        let port = try await forwardOnFreePort(forwarder, macID: "mac-studio")
        #expect(await fetch(port) == nil, "the page gets no reply")
        for _ in 0..<200 where forwarder.refusals[port] == nil { await Task.yield() }
        #expect(forwarder.refusals[port] == "Nothing is listening on port 3000 on this Mac.")
        forwarder.retain(ports: [])
    }

    /// Two tabs restoring the same port at once share one listener.
    @Test func concurrentForwardsOfOnePortShareOneListener() async throws {
        let forwarder = LocalhostForwarder { _, _ in FakeLoopbackChannel(body: "one listener") }
        let port = try await forwardOnFreePort(forwarder, macID: "mac-a")
        forwarder.stop(port)
        async let first: Void = forwarder.forward(port: port, macID: "mac-a")
        async let second: Void = forwarder.forward(port: port, macID: "mac-a")
        _ = try await (first, second)
        #expect(await fetch(port)?.body == "one listener")
        forwarder.retain(ports: [])
    }

    /// A request another site's page sends to the forwarded port never reaches the Mac.
    @Test func aCrossSiteRequestIsDroppedOnThePhone() async throws {
        let log = OpenLog()
        let forwarder = LocalhostForwarder { macID, port in
            log.note(macID, port)
            return FakeLoopbackChannel(body: "dev server")
        }
        let port = try await forwardOnFreePort(forwarder, macID: "mac-a")
        #expect(await fetch(port, origin: "https://evil.example") == nil)
        #expect(log.all.isEmpty, "the Mac never heard of it")
        // The dev app's own origin goes through.
        #expect(await fetch(port, origin: "http://localhost:\(port)")?.body == "dev server")
        forwarder.retain(ports: [])
    }

    /// In the background or unlinked the port stops listening; it comes back after.
    @Test func suspendedPortsListenAgainOnResume() async throws {
        let forwarder = LocalhostForwarder { _, _ in FakeLoopbackChannel(body: "back") }
        let port = try await forwardOnFreePort(forwarder, macID: "mac-a")
        // A served connection leaves this side's TIME_WAIT on the port.
        #expect(await fetch(port)?.body == "back")
        forwarder.suspend()
        #expect(await fetch(port) == nil)
        #expect(forwarder.ports == [port], "the port is still known")
        forwarder.resume()
        var body: String?
        for _ in 0..<100 where body == nil {
            body = await fetch(port)?.body
            if body == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(body == "back")
        forwarder.retain(ports: [])
    }

    /// A port this app just stopped (Mirror, then Open on iPhone again) forwards again
    /// at once: its own closed connections never read as another app's.
    @Test func aPortStoppedLatelyForwardsAgainAtOnce() async throws {
        let forwarder = LocalhostForwarder { _, _ in FakeLoopbackChannel(body: "again") }
        let port = try await forwardOnFreePort(forwarder, macID: "mac-a")
        #expect(await fetch(port)?.body == "again")
        forwarder.stop(port)
        try await forwarder.forward(port: port, macID: "mac-a")
        #expect(await fetch(port)?.body == "again")
        forwarder.retain(ports: [])
    }

    /// No other app can share a forwarded port, even one that asks for address reuse.
    @Test func anotherAppCannotShareAForwardedPort() async throws {
        let forwarder = LocalhostForwarder { _, _ in FakeLoopbackChannel(body: "ours") }
        let port = try await forwardOnFreePort(forwarder, macID: "mac-a")
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let other = try NWListener(using: parameters)
        let failed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = FirstOnly()
            other.stateUpdateHandler = { state in
                let result: Bool? = switch state {
                case .ready: false
                case .failed: true
                default: nil
                }
                if let result, once.take() { continuation.resume(returning: result) }
            }
            other.start(queue: .main)
        }
        other.cancel()
        #expect(failed, "another app's listener bound the forwarded port")
        #expect(await fetch(port)?.body == "ours")
        forwarder.retain(ports: [])
    }

    @Test func aPortTakenOnThisIPhoneIsNotForwarded() async throws {
        let forwarder = LocalhostForwarder { _, _ in FakeLoopbackChannel(body: "x") }
        let port = try await forwardOnFreePort(forwarder, macID: "mac-a")
        forwarder.stop(port)
        // Another app's server on the port (no address reuse), once our listener let go of it.
        var other: NWListener?
        for _ in 0..<100 where other == nil {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: .main)
            for _ in 0..<200 where listener.state == .setup || listener.state == .waiting(.posix(.EADDRINUSE)) {
                try await Task.sleep(for: .milliseconds(5))
            }
            if listener.state == .ready {
                other = listener
            } else {
                listener.cancel()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let server = try #require(other, "the other app's server got the port")
        await #expect(throws: LocalhostForwarder.Failure.portInUse) {
            try await forwarder.forward(port: port, macID: "mac-b")
        }
        #expect(forwarder.ports.isEmpty)
        server.cancel()
    }
}
