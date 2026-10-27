import CmuxNextCompat
import CmuxNextIPC
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// The app's framed IPC negotiation (p05-ipc-092): frames only on a local connection at the daemon's API
/// revision, streams local and bridged, REQUEST frames with the method table's ids, the same replies as lines,
/// and an older daemon that never hears of any of it.
@Suite(.serialized, .timeLimit(.minutes(1))) struct DaemonHandshakeTests {
    // MARK: - Fixtures

    /// The v12 commands the fake daemon and the app both know: family 0x01.
    static let table = MethodTable(v12: [MethodTableFamily(id: 0x01, name: "wire-test", entries: [
        attributes(0x0100, "wire-echo", .control),
        attributes(0x0101, "wire-bulk", .bulk),
        attributes(0x0102, "wire-lines-only", .control),
    ])], v2: [], events: [])

    static func attributes(_ raw: UInt16, _ name: String, _ priority: MethodPriority) -> MethodAttributes {
        MethodAttributes(id: MethodID(rawValue: raw), name: name, priority: priority, ordering: .sequence,
                         durability: .readOnly, payload: .json, streamScoped: false, crossesStreamOK: nil,
                         maxBytes: nil, coalesce: nil, urgent: false)
    }

    struct Echo: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "wire-echo"
        var text: String
    }

    struct Bulk: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "wire-bulk"
        var text: String
    }

    /// A method the daemon serves only as a line: it answers its frame `method_not_framed`.
    struct LinesOnly: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "wire-lines-only"
        var text: String
    }

    /// A command the table does not name: always a line.
    struct Unlisted: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "wire-unlisted"
        var text: String
    }

    /// What the bridge fixture read, in order.
    struct Attempts: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "test-wire-attempts"
    }

    static let frames = WireNegotiation.framesCapability
    static let streams = WireNegotiation.streamsCapability

    static func configuration(upgrades: DaemonWireUpgrades, hello: Bool) -> DaemonConnectionConfiguration {
        var configuration = DaemonConnectionConfiguration(requiredCapabilities: [], requestTimeout: .seconds(5),
                                                          terminalEnvironment: nil,
                                                          clientHello: hello ? ClientHelloIdentity(installKey: nil) : nil)
        configuration.wireUpgrades = upgrades
        return configuration
    }

    static let upgrades = DaemonWireUpgrades(methodTable: table, streams: true)

    /// Connects with `upgrades` and returns the connection and its grants.
    static func connect(_ daemon: WireDaemon, upgrades: DaemonWireUpgrades,
                        hello: Bool = false) async throws -> (DaemonConnection, DaemonWireGrants?) {
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: daemon.path),
                                          configuration: configuration(upgrades: upgrades, hello: hello))
        try await connection.start()
        return (connection, await connection.ready?.transport.wireGrants)
    }

    // MARK: - Negotiation

    /// At the daemon's revision on a local socket, typed commands go as REQUEST frames named by the table, and
    /// each reply equals the lines connection's.
    @Test(arguments: [false, true]) func framesAtEqualRevisionAnswerLikeLines(hello: Bool) async throws {
        let daemon = try WireDaemon(.init(offers: [Self.frames, Self.streams], revision: WireNegotiation.apiRevision))
        defer { daemon.stop() }
        let (lines, linesGrants) = try await Self.connect(daemon, upgrades: .none, hello: hello)
        let (framed, grants) = try await Self.connect(daemon, upgrades: Self.upgrades, hello: hello)
        #expect(linesGrants == .linesOnly)
        #expect(grants == DaemonWireGrants(frames: true, streams: true))

        #expect(try await framed.request(Echo(text: "a")) == lines.request(Echo(text: "a")))
        #expect(try await framed.request(Bulk(text: "b")) == lines.request(Bulk(text: "b")))
        #expect(try await framed.request(Unlisted(text: "c")) == lines.request(Unlisted(text: "c")))
        await lines.close()
        await framed.close()

        let seen = daemon.seen.withLock { $0 }
        let upgraded = seen.filter { $0.connection == 1 }
        let echo = try #require(upgraded.first { $0.cmd == "wire-echo" })
        #expect(echo.framed && echo.methodID == 0x0100 && echo.priority == MethodPriority.control.rawValue)
        let bulk = try #require(upgraded.first { $0.cmd == "wire-bulk" })
        #expect(bulk.framed && bulk.methodID == 0x0101 && bulk.priority == MethodPriority.bulk.rawValue)
        #expect(upgraded.first { $0.cmd == "wire-unlisted" }?.framed == false)
        #expect(seen.filter { $0.connection == 0 }.allSatisfy { !$0.framed }, "the lines connection sent a frame")
        // The grant: frames and streams echoed with this build's revision, then read back by `identify {revisions}`.
        let info = upgraded.filter { $0.cmd == "set-client-info" }
        #expect(info.last?.capabilities.contains(Self.frames) == true && info.last?.capabilities.contains(Self.streams) == true)
        #expect(info.last?.apiRevision == WireNegotiation.apiRevision)
        let revisions = try #require(upgraded.lastIndex { $0.cmd == "identify" && $0.revisions })
        let declared = try #require(upgraded.lastIndex { $0.cmd == "set-client-info" })
        #expect(revisions > declared)
    }

    /// At another revision the daemon withholds frames: streams are granted, and every request stays a line.
    @Test func anotherRevisionKeepsLines() async throws {
        let daemon = try WireDaemon(.init(offers: [Self.frames, Self.streams], revision: WireNegotiation.apiRevision + 1))
        defer { daemon.stop() }
        let (connection, grants) = try await Self.connect(daemon, upgrades: Self.upgrades, hello: true)
        #expect(grants == DaemonWireGrants(frames: false, streams: true))
        #expect(try await connection.request(Echo(text: "a")) == .object(["cmd": .string("wire-echo"), "text": .string("a")]))
        await connection.close()
        #expect(daemon.seen.withLock { $0 }.allSatisfy { !$0.framed })
    }

    /// An older daemon offers nothing and refuses `revisions` and `api_revision`: the connection never sends
    /// them, comes up on lines, and its requests answer as before.
    @Test(arguments: [false, true]) func anOlderDaemonHearsNothingNew(hello: Bool) async throws {
        let daemon = try WireDaemon(.init(offers: [], revision: nil))
        defer { daemon.stop() }
        let (connection, grants) = try await Self.connect(daemon, upgrades: Self.upgrades, hello: hello)
        #expect(grants == .linesOnly)
        #expect(try await connection.request(Echo(text: "a")) == .object(["cmd": .string("wire-echo"), "text": .string("a")]))
        await connection.close()
        let seen = daemon.seen.withLock { $0 }
        #expect(seen.allSatisfy { !$0.framed && !$0.revisions && $0.apiRevision == nil })
        #expect(seen.filter { $0.cmd == "set-client-info" }.count == 1)
        #expect(seen.allSatisfy { !$0.capabilities.contains(Self.frames) && !$0.capabilities.contains(Self.streams) })
    }

    /// A connection that asks for no upgrade echoes none, whatever the daemon offers.
    @Test func noUpgradesEchoNothing() async throws {
        let daemon = try WireDaemon(.init(offers: [Self.frames, Self.streams], revision: WireNegotiation.apiRevision))
        defer { daemon.stop() }
        let (connection, grants) = try await Self.connect(daemon, upgrades: .none)
        #expect(grants == .linesOnly)
        _ = try await connection.request(Echo(text: "a"))
        await connection.close()
        let seen = daemon.seen.withLock { $0 }
        #expect(seen.filter { $0.cmd == "set-client-info" }.count == 1)
        #expect(seen.allSatisfy { !$0.framed && !$0.revisions && $0.apiRevision == nil && $0.capabilities.allSatisfy { $0 != Self.frames } })
    }

    /// A method the daemon serves only as a line is refused on its frame before it runs; the connection sends
    /// it again as a line and keeps sending it as one.
    @Test func aMethodNotFramedGoesAsALine() async throws {
        let daemon = try WireDaemon(.init(offers: [Self.frames], revision: WireNegotiation.apiRevision))
        defer { daemon.stop() }
        let (connection, grants) = try await Self.connect(daemon, upgrades: Self.upgrades, hello: true)
        #expect(grants?.frames == true)
        #expect(try await connection.request(LinesOnly(text: "1")) == .object(["cmd": .string("wire-lines-only"), "text": .string("1")]))
        #expect(try await connection.request(LinesOnly(text: "2")) == .object(["cmd": .string("wire-lines-only"), "text": .string("2")]))
        await connection.close()
        let sends = daemon.seen.withLock { $0 }.filter { $0.cmd == "wire-lines-only" }.map(\.framed)
        #expect(sends == [true, false, false])
    }

    /// Through a byte bridge the daemon may see a direct peer, so the app asks only for streams there.
    @Test func aBridgeAsksOnlyForStreams() async throws {
        let script = #"""
        import json, sys
        seen = []
        print('{"ok":true}', file=sys.stderr, flush=True)
        for line in sys.stdin:
            frame = json.loads(line)
            command = frame.get('cmd')
            result = {}
            if command == 'test-wire-attempts':
                result = seen
            else:
                seen.append(frame)
            if command == 'identify':
                result = {'app':'cmux-tui','protocol':12,'generation':'bridge-test',
                    'capabilities':['ipc-frames-v2','attach-streams-v1']}
                if frame.get('revisions'):
                    result['api_revision'] = 12
            print(json.dumps({'id':frame.get('id'),'ok':True,'data':result}), flush=True)
        """#
        let bridge = DaemonBridge(executable: "/usr/bin/python3", arguments: ["-u", "-c", script])
        let connection = DaemonConnection(
            endpoint: .init(socketPath: "/tmp/cmux-wire-bridge-\(UUID().uuidString.prefix(8)).sock", bridge: bridge),
            configuration: Self.configuration(upgrades: Self.upgrades, hello: false))
        try await connection.start()
        let grants = await connection.ready?.transport.wireGrants
        let attempts = try await connection.request(Attempts())
        await connection.close()
        #expect(grants == DaemonWireGrants(frames: false, streams: true))
        let infos = try #require(attempts.arrayValue).filter { $0["cmd"] == .string("set-client-info") }
        let upgraded = try #require(infos.last?["capabilities"]?.arrayValue)
        #expect(upgraded.contains(.string(Self.streams)) && !upgraded.contains(.string(Self.frames)))
        #expect(infos.allSatisfy { $0["api_revision"] == nil })
    }

    // MARK: - Wire format

    /// The app's revision is cmux-tui/spec/api-compat.json's current one (cmux-api-compat `Schema::current`:
    /// the last revision, else `base`), so frames are asked for exactly where the daemon grants them.
    @Test func apiRevisionIsTheSpecsCurrent() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/api-compat.json"))
        let spec = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let base = try #require((spec["base"] as? NSNumber)?.uint32Value)
        let revisions = spec["revisions"] as? [[String: Any]] ?? []
        let current = (revisions.last?["rev"] as? NSNumber)?.uint32Value ?? base
        #expect(WireNegotiation.apiRevision == current)
    }

    /// A REQUEST frame is cmux-ipc's header (kind 16, stream 0, length, request id, method id, priority, no
    /// flags) and then the request's line without its newline.
    @Test func aRequestFrameIsTheHeaderThenTheLine() {
        let body = Data(#"{"cmd":"wire-bulk","id":7}"#.utf8)
        let method = Self.attributes(0x0101, "wire-bulk", .bulk)
        let frame = FramedRequests.requestFrame(body, requestID: (UInt64(1) << 32) | 7, method: method)
        let length = UInt8(body.count)
        #expect(Array(frame.prefix(16)) == [0xFF, 16, 0, 0, length, 0, 0, 0, 7, 0, 0, 0, 0x01, 0x01, 2, 0])
        #expect(frame.dropFirst(16) == body)
    }

    /// A reply's 32-bit id maps back to the latest request id with those low bits, across the wrap.
    @Test func replyIDsMapBackAcrossTheWrap() {
        let wrap = UInt64(1) << 32
        #expect(FramedRequests.requestID(low: 3, next: 5) == 3)
        #expect(FramedRequests.requestID(low: 2, next: wrap + 5) == wrap + 2)
        #expect(FramedRequests.requestID(low: UInt32.max - 1, next: wrap + 5) == wrap - 2)
    }

    /// The table frames only JSON commands of the connection's sequence that fit their bound and that the
    /// daemon has not refused.
    @Test func onlyTableCommandsAreFramed() {
        var framing = FramedRequests(table: Self.table)
        #expect(framing.method(for: "wire-echo", bodyBytes: 10)?.id == MethodID(rawValue: 0x0100))
        #expect(framing.method(for: "wire-unlisted", bodyBytes: 10) == nil)
        #expect(framing.method(for: "wire-echo", bodyBytes: Int(FrameHeader.maxPayloadCap) + 1) == nil)
        framing.markUnframed(MethodID(rawValue: 0x0100))
        #expect(framing.method(for: "wire-echo", bodyBytes: 10) == nil)
    }
}

/// The real daemon answers the bench ops the same on a connection that negotiates frames and streams as on
/// one that keeps lines, and grants frames exactly where it offers them.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct DaemonHandshakeLiveTests {
    struct ListWorkspaces: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "list-workspaces"
    }

    struct ListTerminals: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "list-terminals"
    }

    struct ListTabGroups: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "list-tab-groups"
    }

    @Test func benchOpsAnswerTheSameFramedAndAsLines() async throws {
        let h = try await BranchDaemonHarness.start()
        var configuration = BranchDaemonHarness.configuration()
        configuration.wireUpgrades = DaemonWireUpgrades(methodTable: MethodTable.schema, streams: true)
        let upgraded = DaemonConnection(endpoint: h.endpoint, configuration: configuration)
        do {
            _ = try await h.workspaceWithTerminal("wire")
            try await upgraded.start()
            let grants = try #require(await upgraded.ready?.transport.wireGrants)
            #expect(grants.frames == h.identity.supports(WireNegotiation.framesCapability))
            #expect(grants.streams == h.identity.supports(WireNegotiation.streamsCapability))
            #expect(try await upgraded.request(ListWorkspaces()) == h.connection.request(ListWorkspaces()))
            #expect(try await upgraded.request(ListTerminals()) == h.connection.request(ListTerminals()))
            #expect(try await upgraded.request(ListTabGroups()) == h.connection.request(ListTabGroups()))
        } catch {
            await upgraded.close()
            await h.stop()
            throw error
        }
        await upgraded.close()
        await h.stop()
    }
}

/// A local daemon that speaks lines and, once granted, REQUEST frames, by the grant rule of cmux-tui
/// capabilities.rs: frames at its own revision, after the client echoes them.
final class WireDaemon: Sendable {
    struct Script: Sendable {
        /// The framed IPC capabilities `identify` offers.
        var offers: [String]
        /// Its API revision; nil is a daemon from before revisions, which refuses `revisions` and `api_revision`.
        var revision: UInt32?
    }

    /// One request as the daemon read it.
    struct Seen: Sendable {
        var connection: Int
        var cmd: String
        var framed: Bool
        var methodID: UInt16?
        var priority: UInt8?
        var revisions = false
        var apiRevision: UInt32?
        var capabilities: [String] = []
    }

    let path = "/tmp/cnd-hs-\(UUID().uuidString.prefix(8).lowercased()).sock"
    let seen = Mutex<[Seen]>([])
    private let listener: Int32
    private let script: Script

    init(_ script: Script) throws {
        self.script = script
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        self.listener = listener
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            close(listener)
            throw POSIXError(.EADDRINUSE)
        }
        let thread = Thread { [self] in
            var index = 0
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                let connection = index
                index += 1
                let serving = Thread { [self] in serve(client, connection: connection) }
                serving.start()
            }
        }
        thread.start()
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }

    private enum Message {
        case line([UInt8])
        case frame(header: [UInt8], body: [UInt8])
    }

    /// One connection's grant state.
    private struct Session {
        var declared: UInt32?
        var framesGranted = false
    }

    private func serve(_ client: Int32, connection: Int) {
        defer { close(client) }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var session = Session()
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer += chunk[0..<count]
            while let message = Self.cut(&buffer) {
                guard handle(message, session: &session, connection: connection, client: client) else { return }
            }
        }
    }

    private static func cut(_ buffer: inout [UInt8]) -> Message? {
        guard let first = buffer.first else { return nil }
        if first == 0xFF {
            guard buffer.count >= 16 else { return nil }
            let length = Int(UInt32(buffer[4]) | UInt32(buffer[5]) << 8 | UInt32(buffer[6]) << 16 | UInt32(buffer[7]) << 24)
            guard buffer.count >= 16 + length else { return nil }
            let message = Message.frame(header: Array(buffer[0..<16]), body: Array(buffer[16..<16 + length]))
            buffer.removeFirst(16 + length)
            return message
        }
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = Array(buffer[0..<newline])
        buffer.removeFirst(newline + 1)
        return .line(line)
    }

    /// Answers one message; false closes the connection (a bad message).
    private func handle(_ message: Message, session: inout Session, connection: Int, client: Int32) -> Bool {
        switch message {
        case .line(let bytes):
            guard let request = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  let cmd = request["cmd"] as? String else { return false }
            var seen = Seen(connection: connection, cmd: cmd, framed: false)
            seen.revisions = request["revisions"] as? Bool == true
            seen.apiRevision = (request["api_revision"] as? NSNumber)?.uint32Value
            seen.capabilities = request["capabilities"] as? [String] ?? []
            self.seen.withLock { $0.append(seen) }
            let reply: [String: Any]
            if let data = answer(cmd, request: request, session: &session) {
                reply = ["id": request["id"] ?? NSNull(), "ok": true, "data": data]
            } else {
                reply = ["id": request["id"] ?? NSNull(), "ok": false, "error": "unknown field", "error_code": "bad_request"]
            }
            return Self.write(Self.json(reply), to: client)
        case .frame(let header, let body):
            let methodID = UInt16(header[12]) | UInt16(header[13]) << 8
            guard session.framesGranted, header[1] == 16, header[2] == 0, header[3] == 0, header[15] == 0,
                  let method = DaemonHandshakeTests.table.v12(MethodID(rawValue: methodID)),
                  method.priority.rawValue == header[14],
                  let request = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
                  request["cmd"] as? String == method.name else { return false }
            self.seen.withLock {
                $0.append(Seen(connection: connection, cmd: method.name, framed: true, methodID: methodID, priority: header[14]))
            }
            let refused = method.name == "wire-lines-only"
            let reply: [String: Any] = refused
                ? ["ok": false, "error": "send it as a line", "error_code": FramedRequests.methodNotFramed]
                : ["id": request["id"] ?? NSNull(), "ok": true, "data": answer(method.name, request: request, session: &session) ?? [String: Any]()]
            var frame = header
            frame[1] = refused ? 18 : 17
            let payload = Self.json(reply)
            let length = UInt32(payload.count)
            for byte in 0..<4 { frame[4 + byte] = UInt8(truncatingIfNeeded: length >> (8 * UInt32(byte))) }
            return Self.write(Data(frame) + payload, to: client, newline: false)
        }
    }

    /// The `data` of a command, or nil for a refusal.
    private func answer(_ cmd: String, request: [String: Any], session: inout Session) -> Any? {
        switch cmd {
        case "identify":
            if request["revisions"] != nil, script.revision == nil { return nil }
            var offers = script.offers
            if let declared = session.declared, declared != script.revision { offers.removeAll { $0 == WireNegotiation.framesCapability } }
            var identity: [String: Any] = ["app": "cmux-tui", "protocol": 12, "generation": "wire-test", "capabilities": offers]
            if request["revisions"] as? Bool == true, let revision = script.revision { identity["api_revision"] = revision }
            return identity
        case "set-client-info":
            let declared = (request["api_revision"] as? NSNumber)?.uint32Value
            if declared != nil, script.revision == nil { return nil }
            if let declared { session.declared = declared }
            let capabilities = request["capabilities"] as? [String] ?? []
            session.framesGranted = capabilities.contains(WireNegotiation.framesCapability)
                && script.offers.contains(WireNegotiation.framesCapability)
                && session.declared != nil && session.declared == script.revision
            return [String: Any]()
        case "client-hello":
            return ["connection_id": "wire-test"]
        case "subscribe":
            return [String: Any]()
        default:
            return ["cmd": cmd, "text": request["text"] ?? NSNull()] as [String: Any]
        }
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static func write(_ message: Data, to client: Int32, newline: Bool = true) -> Bool {
        var bytes = message
        if newline { bytes.append(0x0A) }
        return bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(client, base + offset, raw.count - offset, 0)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
