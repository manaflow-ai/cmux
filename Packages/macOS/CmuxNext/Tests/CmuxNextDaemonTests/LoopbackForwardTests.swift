import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// `LoopbackForwardClient` against a scripted daemon: opt-in handshake,
/// error mapping, echo through a stream, credit flow control both ways, and
/// a dropped connection failing streams (never a fallback).
@Suite(.timeLimit(.minutes(1))) struct LoopbackForwardTests {
    static let identify = ConnectionTests.identify.replacingOccurrences(
        of: #""attach-initial-size""#, with: #""attach-initial-size","loopback-forward-v1""#)

    /// Requests the fake saw, in order.
    final class Log: Sendable {
        let requests = Mutex<[[String: JSONValue]]>([])
        func append(_ request: [String: JSONValue]) { requests.withLock { $0.append(request) } }
        func commands() -> [String] { requests.withLock { $0.compactMap { $0["cmd"]?.stringValue } } }
        func all(_ cmd: String) -> [[String: JSONValue]] { requests.withLock { $0.filter { $0["cmd"]?.stringValue == cmd } } }
    }

    /// A daemon that answers the handshake and `loopback-open`, echoes data
    /// (optionally returning credit), and records everything.
    static func server(identify: String = identify, window: Int = 262_144, openError: String? = nil,
                       echo: Bool = true, credit: Bool = true, log: Log) throws -> FakeDaemonServer {
        try FakeDaemonServer { request in
            log.append(request)
            let id = request["id"]?.intValue ?? 0
            let stream = request["stream"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify":
                return [#"{"id":\#(id),"ok":true,"data":\#(identify.replacingOccurrences(of: "GEN", with: "g"))}"#]
            case "set-client-info":
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            case "loopback-open":
                if let openError {
                    return [#"{"id":\#(id),"ok":false,"error":"refused","error_code":"\#(openError)"}"#]
                }
                return [#"{"id":\#(id),"ok":true,"data":{"stream":\#(stream),"address":"127.0.0.1:5173","window":\#(window)}}"#]
            case "loopback-data":
                let data = request["data"]?.stringValue ?? ""
                let size = Data(base64Encoded: data)?.count ?? 0
                var lines: [String] = []
                if credit { lines.append(#"{"event":"loopback-credit","stream":\#(stream),"bytes":\#(size)}"#) }
                if echo { lines.append(#"{"event":"loopback-data","stream":\#(stream),"data":"\#(data)"}"#) }
                return lines
            case "loopback-shutdown":
                return [#"{"event":"loopback-eof","stream":\#(stream)}"#, #"{"event":"loopback-closed","stream":\#(stream)}"#]
            default:
                return []
            }
        }
    }

    static func client(_ server: FakeDaemonServer) -> LoopbackForwardClient {
        let path = server.path
        return LoopbackForwardClient { DaemonEndpoint(socketPath: path) }
    }

    /// Collects stream events until `.closed` or `limit` bytes.
    static func collect(_ stream: LoopbackStream, bytes limit: Int = .max) async -> (Data, [LoopbackStreamEvent]) {
        var data = Data()
        var others: [LoopbackStreamEvent] = []
        for await event in stream.events {
            switch event {
            case .data(let chunk):
                data.append(chunk)
                stream.consumed(chunk.count)
                if data.count >= limit { return (data, others) }
            case .eof:
                others.append(event)
            case .closed:
                others.append(event)
                return (data, others)
            }
        }
        return (data, others)
    }

    @Test func openOptsInOnItsOwnConnectionAndEchoesBytes() async throws {
        let log = Log()
        let server = try Self.server(log: log)
        defer { server.stop() }
        let client = Self.client(server)
        let stream = try await client.open(host: "localhost", port: 5173)
        #expect(stream.address == "127.0.0.1:5173")
        let info = try #require(log.all("set-client-info").first)
        #expect(info["capabilities"]?.arrayValue?.compactMap(\.stringValue) == ["loopback-forward-v1"])
        #expect(log.commands().contains("subscribe") == false, "the forwarding connection never subscribes")

        let payload = Data("GET / HTTP/1.1\r\nHost: localhost:5173\r\n\r\n".utf8)
        try await stream.write(payload)
        stream.shutdownWrite()
        let (echoed, events) = await Self.collect(stream)
        #expect(echoed == payload)
        #expect(events == [.eof, .closed(error: nil)])
        let open = try #require(log.all("loopback-open").first)
        #expect(open["host"]?.stringValue == "localhost")
        #expect(open["port"]?.intValue == 5173)
        #expect(open["window"]?.intValue == LoopbackForwardClient.receiveWindow)
        await client.close()
    }

    @Test func aDaemonWithoutTheCapabilityIsUnsupported() async throws {
        let log = Log()
        let server = try Self.server(identify: ConnectionTests.identify, log: log)
        defer { server.stop() }
        let client = Self.client(server)
        await #expect(throws: LoopbackForwardError.unsupported) { try await client.open(host: "localhost", port: 3000) }
        #expect(log.all("loopback-open").isEmpty)
    }

    @Test func daemonRefusalsMapToTypedErrors() async throws {
        for (code, expected) in [("loopback.denied-host", LoopbackForwardError.deniedHost),
                                 ("loopback.refused", .refused), ("loopback.disabled", .disabled),
                                 ("loopback.denied-port", .deniedPort)] {
            let log = Log()
            let server = try Self.server(openError: code, log: log)
            defer { server.stop() }
            let client = Self.client(server)
            await #expect(throws: expected) { try await client.open(host: "localhost", port: 3000) }
            #expect(await client.openStreamCount == 0)
            await client.close()
        }
    }

    @Test func writesNeverExceedTheDaemonWindow() async throws {
        let log = Log()
        // A 10-byte daemon window: every frame waits for the credit the
        // fake returns after it.
        let server = try Self.server(window: 10, echo: false, log: log)
        defer { server.stop() }
        let client = Self.client(server)
        let stream = try await client.open(host: "127.0.0.1", port: 8080)
        try await stream.write(Data(repeating: 7, count: 35))
        // The fake answers the shutdown after reading every data line.
        stream.shutdownWrite()
        _ = await Self.collect(stream)
        let sizes = log.all("loopback-data").compactMap { Data(base64Encoded: $0["data"]?.stringValue ?? "")?.count }
        #expect(sizes == [10, 10, 10, 5])
        await client.close()
    }

    /// Records stream lines instead of writing a socket.
    final class RecordingSender: LoopbackLineSending {
        let lines = Mutex<[Data]>([])
        func send(_ line: Data) -> Bool {
            lines.withLock { $0.append(line) }
            return true
        }

        var credits: [Int] {
            lines.withLock { lines in
                lines.compactMap { line -> Int? in
                    guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: line),
                          object["cmd"]?.stringValue == "loopback-credit" else { return nil }
                    return object["bytes"]?.intValue
                }
            }
        }
    }

    @Test func consumedBytesReturnCreditInQuarterWindowBatches() {
        let sender = RecordingSender()
        let stream = LoopbackStream(id: 1, receiveWindow: 1000, sender: sender, onFinish: { _ in })
        stream.deliver(.data(stream: 1, bytes: Data(count: 600)))
        stream.consumed(100)
        #expect(sender.credits.isEmpty, "below a quarter window and bytes still buffered")
        stream.consumed(200)
        #expect(sender.credits == [300])
        stream.consumed(300)
        #expect(sender.credits == [300, 300], "an empty buffer returns the rest at once")
    }

    @Test func aDroppedConnectionFailsOpenStreams() async throws {
        let log = Log()
        let server = try Self.server(echo: false, log: log)
        defer { server.stop() }
        let client = Self.client(server)
        let stream = try await client.open(host: "localhost", port: 3000)
        server.disconnectClient()
        let (_, events) = await Self.collect(stream)
        guard case .closed(let error)? = events.last, case .connectionLost? = error else {
            Issue.record("expected connectionLost, got \(events)")
            return
        }
        await #expect(throws: LoopbackStreamError.self) { try await stream.write(Data("x".utf8)) }
    }

    @Test func dataPastTheReceiveWindowEndsTheStream() async throws {
        let log = Log()
        let server = try Self.server(echo: false, log: log)
        defer { server.stop() }
        let client = Self.client(server)
        let stream = try await client.open(host: "localhost", port: 3000)
        // Nothing consumed: more than one window from the "daemon".
        let chunk = Data(repeating: 2, count: 64 * 1024).base64EncodedString()
        for _ in 0...(LoopbackForwardClient.receiveWindow / (64 * 1024)) {
            server.push(#"{"event":"loopback-data","stream":\#(stream.id),"data":"\#(chunk)"}"#)
        }
        var last: LoopbackStreamEvent?
        for await event in stream.events { last = event }
        #expect(last == .closed(error: .protocolViolation("the daemon sent past the window")))
        await client.close()
    }

    @Test func eventLinesDecode() {
        let data = Data(#"{"event":"loopback-data","stream":3,"data":"aGk="}"#.utf8)
        #expect(LoopbackForwardEvent.decode(name: "loopback-data", line: data) == .data(stream: 3, bytes: Data("hi".utf8)))
        let closed = Data(#"{"event":"loopback-closed","stream":3,"error":"reset"}"#.utf8)
        #expect(LoopbackForwardEvent.decode(name: "loopback-closed", line: closed) == .closed(stream: 3, error: "reset"))
        #expect(LoopbackForwardEvent.decode(name: "tree-changed", line: data) == nil)
        let bad = Data(#"{"event":"loopback-data","stream":3,"data":"%%%"}"#.utf8)
        #expect(LoopbackForwardEvent.decode(name: "loopback-data", line: bad) == nil)
    }
}
