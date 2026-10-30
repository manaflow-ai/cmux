import CmuxMobileTransport
import Foundation
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
    func fetch(_ port: UInt16, path: String = "/") async -> (status: Int, body: String)? {
        let session = URLSession(configuration: .ephemeral)
        guard let (data, response) = try? await session.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!) else { return nil }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    /// A free port on this machine's loopback (a forward on a used one says `portInUse`).
    func forwardOnFreePort(_ forwarder: LocalhostForwarder, macID: String?) async throws -> UInt16 {
        for _ in 0..<20 {
            let port = UInt16.random(in: 20000...60000)
            do {
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

    @Test func aPortTakenOnThisIPhoneIsNotForwarded() async throws {
        let first = LocalhostForwarder { _, _ in FakeLoopbackChannel(body: "first") }
        let port = try await forwardOnFreePort(first, macID: "mac-a")
        let second = LocalhostForwarder { _, _ in FakeLoopbackChannel(body: "second") }
        await #expect(throws: LocalhostForwarder.Failure.portInUse) {
            try await second.forward(port: port, macID: "mac-b")
        }
        #expect(second.ports.isEmpty)
        // The same forwarder moves the port to another Mac instead.
        try await first.forward(port: port, macID: "mac-b")
        #expect(await fetch(port)?.body == "first")
        first.retain(ports: [])
    }
}
