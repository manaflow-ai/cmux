import CmuxNextCompat
import CmuxNextIPC
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// The app's framed IPC negotiation: frames only on a local connection at the daemon's API
/// revision with the daemon's schema, only for the methods it answers on frames, streams local and bridged,
/// REQUEST frames with the method table's ids, the same replies as lines, and an older daemon that never hears
/// of any of it.
@Suite(.serialized, .timeLimit(.minutes(1))) struct DaemonHandshakeTests {
    // MARK: - Fixtures

    /// The v12 commands the fake daemon and the app both know: family 0x01.
    static let table = MethodTable(v12: [MethodTableFamily(id: 0x01, name: "wire-test", entries: [
        attributes(0x0100, "wire-echo", .control),
        attributes(0x0101, "wire-bulk", .bulk),
        attributes(0x0102, "wire-lines-only", .control),
    ])], v2: [], events: [])

    /// A newer app's table: one more command than ``table``, at the same API revision.
    static let newerTable = MethodTable(v12: [MethodTableFamily(id: 0x01, name: "wire-test", entries: [
        attributes(0x0100, "wire-echo", .control),
        attributes(0x0101, "wire-bulk", .bulk),
        attributes(0x0102, "wire-lines-only", .control),
        attributes(0x0103, "wire-new", .control),
    ])], v2: [], events: [])

    static func identity(digest: UInt64) -> WireSchemaIdentity {
        WireSchemaIdentity(muxProtocol: "cmux-mux", muxProtocolVersion: 12, resourceProtocol: "cmux.protocol/2",
                           commandCount: 3, eventCount: 0, resourceOperationCount: 0, localOperationCount: 0,
                           sdkSchemaDigest: digest, resourceOperationsDigest: 0)
    }

    /// The schema ``table`` came from, and the newer one of ``newerTable``.
    static let schema = DaemonFrameSchema(table: table, identity: identity(digest: 0x0123_4567_89AB_CDEF))
    static let newerSchema = DaemonFrameSchema(table: newerTable, identity: identity(digest: 0xFEDC_BA98_7654_3210))
    /// The methods the fake daemon answers on frames: `wire-lines-only` stays a line.
    static let served: [UInt16] = [0x0100, 0x0101]

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

    /// A command only the newer table names.
    struct New: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "wire-new"
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

    static let upgrades = DaemonWireUpgrades(frames: schema, streams: true)

    /// A daemon at this build's revision with `schema`'s tables, answering ``served`` on frames.
    static func daemon(offers: [String] = [DaemonHandshakeTests.frames, DaemonHandshakeTests.streams],
                       schema: DaemonFrameSchema = DaemonHandshakeTests.schema,
                       revision: UInt32? = WireNegotiation.apiRevision) -> WireDaemon.Script {
        WireDaemon.Script(offers: offers, revision: revision, table: schema.table,
                          digest: WireNegotiation.digestText(schema.identity.sdkSchemaDigest), served: Self.served)
    }

    /// Connects with `upgrades` and returns the connection and its grants.
    static func connect(_ daemon: WireDaemon, upgrades: DaemonWireUpgrades,
                        hello: Bool = false) async throws -> (DaemonConnection, DaemonWireGrants?) {
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: daemon.path),
                                          configuration: configuration(upgrades: upgrades, hello: hello))
        try await connection.start()
        return (connection, await connection.ready?.transport.wireGrants)
    }

    // MARK: - Negotiation

    /// At the daemon's revision with its schema on a local socket, the commands it answers on frames go as
    /// REQUEST frames named by the table, the rest stay lines, and each reply equals the lines connection's.
    @Test(arguments: [false, true]) func framesAtEqualRevisionAnswerLikeLines(hello: Bool) async throws {
        let daemon = try WireDaemon(Self.daemon())
        defer { daemon.stop() }
        let (lines, linesGrants) = try await Self.connect(daemon, upgrades: .none, hello: hello)
        let (framed, grants) = try await Self.connect(daemon, upgrades: Self.upgrades, hello: hello)
        #expect(linesGrants == .linesOnly)
        #expect(grants == DaemonWireGrants(frames: true, streams: true))

        #expect(try await framed.request(Echo(text: "a")) == lines.request(Echo(text: "a")))
        #expect(try await framed.request(Bulk(text: "b")) == lines.request(Bulk(text: "b")))
        #expect(try await framed.request(LinesOnly(text: "c")) == lines.request(LinesOnly(text: "c")))
        #expect(try await framed.request(Unlisted(text: "d")) == lines.request(Unlisted(text: "d")))
        await lines.close()
        await framed.close()

        let seen = daemon.seen.withLock { $0 }
        let upgraded = seen.filter { $0.connection == 1 }
        let echo = try #require(upgraded.first { $0.cmd == "wire-echo" })
        #expect(echo.framed && echo.methodID == 0x0100 && echo.priority == MethodPriority.control.rawValue)
        let bulk = try #require(upgraded.first { $0.cmd == "wire-bulk" })
        #expect(bulk.framed && bulk.methodID == 0x0101 && bulk.priority == MethodPriority.bulk.rawValue)
        // In the table but not answered on frames by this daemon: a line, never tried as a frame.
        #expect(upgraded.filter { $0.cmd == "wire-lines-only" }.map(\.framed) == [false])
        #expect(upgraded.first { $0.cmd == "wire-unlisted" }?.framed == false)
        #expect(seen.filter { $0.connection == 0 }.allSatisfy { !$0.framed }, "the lines connection sent a frame")
        #expect(daemon.refusedFrames.withLock { $0 } == 0)
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
        let daemon = try WireDaemon(Self.daemon(revision: WireNegotiation.apiRevision + 1))
        defer { daemon.stop() }
        let (connection, grants) = try await Self.connect(daemon, upgrades: Self.upgrades, hello: true)
        #expect(grants == DaemonWireGrants(frames: false, streams: true))
        #expect(try await connection.request(Echo(text: "a")) == .object(["cmd": .string("wire-echo"), "text": .string("a")]))
        await connection.close()
        #expect(daemon.seen.withLock { $0 }.allSatisfy { !$0.framed })
    }

    /// A newer app and an older running daemon at the same API revision: a command added since that daemon was
    /// built is in the app's table only. The schema digests differ, so the app keeps lines; the new command
    /// gets the daemon's ordinary reply on its line, and the connection stays open for the next request.
    @Test(arguments: [false, true]) func anotherSchemaAtTheSameRevisionKeepsLines(hello: Bool) async throws {
        let daemon = try WireDaemon(Self.daemon())
        defer { daemon.stop() }
        let newer = DaemonWireUpgrades(frames: Self.newerSchema, streams: true)
        let (connection, grants) = try await Self.connect(daemon, upgrades: newer, hello: hello)
        #expect(grants == DaemonWireGrants(frames: false, streams: true))
        #expect(try await connection.request(New(text: "n")) == .object(["cmd": .string("wire-new"), "text": .string("n")]))
        #expect(try await connection.request(Echo(text: "a")) == .object(["cmd": .string("wire-echo"), "text": .string("a")]))
        #expect(await connection.ready?.transport.isClosed == false)
        await connection.close()
        #expect(daemon.seen.withLock { $0 }.allSatisfy { !$0.framed })
        #expect(daemon.refusedFrames.withLock { $0 } == 0)
    }

    /// A daemon that offers frames but does not name its schema or framed methods (or names none) gets no
    /// frames: nothing is ever framed on a guess.
    @Test func aDaemonThatListsNoFramedMethodsKeepsLines() async throws {
        var script = Self.daemon()
        script.digest = nil
        let daemon = try WireDaemon(script)
        defer { daemon.stop() }
        let (connection, grants) = try await Self.connect(daemon, upgrades: Self.upgrades, hello: true)
        #expect(grants == DaemonWireGrants(frames: false, streams: true))
        _ = try await connection.request(Echo(text: "a"))
        await connection.close()
        #expect(daemon.seen.withLock { $0 }.allSatisfy { !$0.framed })
    }

    /// Two requests written back to back, the first of a method the daemon answers only as a line: the daemon
    /// runs them in submit order, and neither is refused or sent twice (p05-ipc.md 3.4, one control sequence).
    @Test func pipelinedRequestsRunInSubmitOrder() async throws {
        let daemon = try WireDaemon(Self.daemon())
        defer { daemon.stop() }
        let (connection, grants) = try await Self.connect(daemon, upgrades: Self.upgrades, hello: true)
        #expect(grants?.frames == true)
        let transport = try #require(await connection.ready?.transport)
        let first = ReplySlot(), second = ReplySlot()
        transport.submit(.reply(cmd: LinesOnly.commandName.wire, first), framed: true) {
            try WireCoding.encodeRequest(LinesOnly(text: "1"), id: $0)
        }
        transport.submit(.reply(cmd: Echo.commandName.wire, second), framed: true) {
            try WireCoding.encodeRequest(Echo(text: "2"), id: $0)
        }
        let replies = try await (first.value(), second.value())
        #expect(try WireCoding.decodeResponse(JSONValue.self, from: replies.0) == .object(["cmd": .string("wire-lines-only"), "text": .string("1")]))
        #expect(try WireCoding.decodeResponse(JSONValue.self, from: replies.1) == .object(["cmd": .string("wire-echo"), "text": .string("2")]))
        await connection.close()
        let ran = daemon.seen.withLock { $0 }.filter { $0.cmd.hasPrefix("wire-") }
        #expect(ran.map(\.cmd) == ["wire-lines-only", "wire-echo"])
        #expect(ran.map(\.framed) == [false, true])
        #expect(daemon.refusedFrames.withLock { $0 } == 0)
    }

    /// An older daemon offers nothing and refuses `revisions` and `api_revision`: the connection never sends
    /// them, comes up on lines, and its requests answer as before.
    @Test(arguments: [false, true]) func anOlderDaemonHearsNothingNew(hello: Bool) async throws {
        let daemon = try WireDaemon(Self.daemon(offers: [], revision: nil))
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
        let daemon = try WireDaemon(Self.daemon())
        defer { daemon.stop() }
        let (connection, grants) = try await Self.connect(daemon, upgrades: .none)
        #expect(grants == .linesOnly)
        _ = try await connection.request(Echo(text: "a"))
        await connection.close()
        let seen = daemon.seen.withLock { $0 }
        #expect(seen.filter { $0.cmd == "set-client-info" }.count == 1)
        #expect(seen.allSatisfy { !$0.framed && !$0.revisions && $0.apiRevision == nil && $0.capabilities.allSatisfy { $0 != Self.frames } })
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

    /// The digest is written as the daemon writes `sdk_schema_digest` (frame_dispatch.rs `{:016x}`).
    @Test func theSchemaDigestIsSixteenLowercaseHexDigits() {
        #expect(WireNegotiation.digestText(0xAB) == "00000000000000ab")
        #expect(WireNegotiation.digestText(0xFEDC_BA98_7654_3210) == "fedcba9876543210")
        #expect(WireNegotiation.digestText(0) == "0000000000000000")
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

    /// Only JSON commands of the table that the daemon answers on frames and that fit their bound are framed.
    @Test func onlyServedTableCommandsAreFramed() {
        let framing = FramedRequests(table: Self.table, served: Set(Self.served.map { MethodID(rawValue: $0) }))
        #expect(framing.method(for: "wire-echo", bodyBytes: 10)?.id == MethodID(rawValue: 0x0100))
        #expect(framing.method(for: "wire-lines-only", bodyBytes: 10) == nil)
        #expect(framing.method(for: "wire-unlisted", bodyBytes: 10) == nil)
        #expect(framing.method(for: "wire-echo", bodyBytes: Int(FrameHeader.maxPayloadCap) + 1) == nil)
    }
}

/// The real daemon answers the bench ops the same on a connection that negotiates frames and streams as on
/// one that keeps lines, and the upgraded connection sends them as REQUEST frames.
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

    /// `server-stats` `ipc`: the daemon's count of framed requests (server_stats.rs, frame_dispatch.rs).
    struct ServerStats: DaemonRequest {
        typealias Response = JSONValue
        static let commandName: DaemonCommandName = "server-stats"
        var include = ["ipc"]
    }

    static func framedRequests(_ connection: DaemonConnection) async throws -> Double {
        let stats = try await connection.request(ServerStats())
        return stats["ipc"]?["parses"]?["frames"]?["requests"]?.doubleValue ?? 0
    }

    @Test func benchOpsAnswerTheSameFramedAndAsLines() async throws {
        let h = try await BranchDaemonHarness.start()
        var configuration = BranchDaemonHarness.configuration()
        configuration.wireUpgrades = DaemonWireUpgrades(frames: DaemonFrameSchema(table: .schema, identity: .built),
                                                        streams: true)
        let upgraded = DaemonConnection(endpoint: h.endpoint, configuration: configuration)
        do {
            _ = try await h.workspaceWithTerminal("wire")
            try await upgraded.start()
            let grants = try #require(await upgraded.ready?.transport.wireGrants)
            #expect(grants.streams == h.identity.supports(WireNegotiation.streamsCapability))
            let before = try await Self.framedRequests(h.connection)
            #expect(try await upgraded.request(ListWorkspaces()) == h.connection.request(ListWorkspaces()))
            #expect(try await upgraded.request(ListTerminals()) == h.connection.request(ListTerminals()))
            #expect(try await upgraded.request(ListTabGroups()) == h.connection.request(ListTabGroups()))
            let framed = try await Self.framedRequests(h.connection) - before
            // The acceptance needs the three ops on frames. The daemon binds no `ipc-frames-v2` transport yet
            // (capabilities.rs `IpcTransports::BOUND` is empty), so it offers none and every op above went as a
            // line. The day it binds one this known issue is not recorded, the test fails, and the wrapper goes.
            withKnownIssue("cmux-tui offers no ipc-frames-v2 yet: IpcTransports::BOUND is empty") {
                try #require(h.identity.supports(WireNegotiation.framesCapability))
                #expect(grants.frames)
                #expect(framed >= 3)
            }
        } catch {
            await upgraded.close()
            await h.stop()
            throw error
        }
        await upgraded.close()
        await h.stop()
    }
}
