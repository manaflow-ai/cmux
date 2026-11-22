import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// The connect path's requests that do not depend on each other's replies go
/// out together (one daemon round trip), so app launch waits for one reply
/// instead of a chain. Each fake daemon here answers a group only after the
/// whole group arrived: a client that waits for one reply before it sends
/// the next request never gets one and misses its deadline.
@Suite(.timeLimit(.minutes(1))) struct StartupPipelineTests {
    /// Holds requests until every command in `group` arrived, then answers
    /// them in arrival order. Other commands go to `other`.
    final class HeldGroup: Sendable {
        let group: Set<String>
        let arrivals = Mutex<[(cmd: String, id: Int)]>([])
        let reply: @Sendable (String, Int) -> String

        init(_ group: Set<String>, reply: @escaping @Sendable (String, Int) -> String) {
            self.group = group
            self.reply = reply
        }

        /// The replies to write now: none until the group is complete.
        func receive(_ cmd: String, id: Int) -> [String] {
            let complete: [(cmd: String, id: Int)]? = arrivals.withLock { arrivals in
                arrivals.append((cmd, id))
                return Set(arrivals.map(\.cmd)) == group ? arrivals : nil
            }
            return complete?.map { reply($0.cmd, $0.id) } ?? []
        }

        var order: [String] { arrivals.withLock { $0.map(\.cmd) } }
    }

    static let quick = DaemonConnection.Configuration(requestTimeout: .milliseconds(800), snapshotTimeout: .milliseconds(800),
                                                      terminalEnvironment: nil)

    @Test func handshakeSendsIdentifyClientInfoAndSubscribeTogether() async throws {
        let held = HeldGroup(["identify", "set-client-info", "subscribe"]) { cmd, id in
            cmd == "identify" ? #"{"id":\#(id),"ok":true,"data":\#(ConnectionTests.identify)}"#
                : #"{"id":\#(id),"ok":true,"data":{}}"#
        }
        let server = try FakeDaemonServer { request in
            held.receive(request["cmd"]?.stringValue ?? "", id: request["id"]?.intValue ?? 0)
        }
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path), configuration: Self.quick)
        let identity = try await connection.start()
        #expect(identity.session == "t")
        // Wire order is kept: identify first, then the client info, then subscribe.
        #expect(held.order == ["identify", "set-client-info", "subscribe"])
        await connection.close()
    }

    @Test func snapshotRequestsTreeSavedGroupsAndPersonalTogether() async throws {
        let identify = ConnectionTests.identify.replacingOccurrences(
            of: #""attach-initial-size""#, with: #""attach-initial-size","saved-tab-groups-v1","profiles-v1""#)
        let held = HeldGroup(["list-workspaces", "list-saved-tab-groups", "list-personal"]) { cmd, id in
            switch cmd {
            case "list-workspaces": #"{"id":\#(id),"ok":true,"data":{"workspace_revision":4,"workspaces":[]}}"#
            case "list-saved-tab-groups": #"{"id":\#(id),"ok":true,"data":{"saved_groups":[]}}"#
            default: #"{"id":\#(id),"ok":true,"data":{"personal_revision":9}}"#
            }
        }
        let server = try FakeDaemonServer { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(identify)}"#]
            case "set-client-info", "subscribe": return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            case let cmd?: return held.receive(cmd, id: id)
            case nil: return []
            }
        }
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path), configuration: Self.quick)
        try await connection.start()
        let (tree, _) = try await connection.snapshot()
        #expect(tree.workspaceRevision == 4)
        #expect(tree.personal?.revision == 9)
        #expect(held.order.first == "list-workspaces")
        await connection.close()
    }

    @Test func terminalAttachSendsIdentifyAndClientInfoTogether() async throws {
        let held = HeldGroup(["identify", "set-client-info"]) { cmd, id in
            cmd == "identify" ? #"{"id":\#(id),"ok":true,"data":\#(ConnectionTests.identify)}"#
                : #"{"id":\#(id),"ok":true,"data":{}}"#
        }
        let server = try FakeDaemonServer { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "attach-surface":
                return [#"{"event":"vt-state","surface":7,"cols":80,"rows":24,"data":""}"#,
                        #"{"id":\#(id),"ok":true,"data":{"lease":"L"}}"#]
            case let cmd?: return held.receive(cmd, id: id)
            case nil: return []
            }
        }
        defer { server.stop() }
        let attachment = try await TerminalAttachment.attach(
            endpoint: DaemonEndpoint(socketPath: server.path), target: .init(surface: 7),
            size: CellSize(cols: 80, rows: 24), claimGeometry: false)
        #expect(held.order == ["identify", "set-client-info"])
        await attachment.detach()
    }

    @Test func aGroupPastItsDeadlineFailsEveryRequestAndALateReplyIsDropped() async throws {
        let held = Mutex<[Int]>([])
        let server = try FakeDaemonServer { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify", "subscribe":
                held.withLock { $0.append(id) }
                return []
            case "ping":
                // Answers the held group late, then this request.
                return held.withLock { $0 }.map { #"{"id":\#($0),"ok":true,"data":{}}"# } + [#"{"id":\#(id),"ok":true,"data":{"pong":true}}"#]
            default: return []
            }
        }
        defer { server.stop() }
        let transport = try LineTransport(path: server.path)
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        defer { transport.close() }
        let results = await transport.pipeline([PipelinedLine(IdentifyRequest()), PipelinedLine(SubscribeRequest(treeEvents: .deltas))],
                                               timeout: .milliseconds(200))
        for result in results {
            #expect(throws: DaemonError.self) { try result.get() }
        }
        let reply = try await transport.request(cmd: "ping", timeout: .seconds(5)) { id in Data(#"{"id":\#(id),"cmd":"ping"}"#.utf8) }
        #expect(String(decoding: reply.line, as: UTF8.self).contains("pong"))
    }

    @Test func aConnectionLostMidGroupFailsEveryRequest() async throws {
        let box = Mutex<FakeDaemonServer?>(nil)
        let server = try FakeDaemonServer { request in
            if request["cmd"]?.stringValue == "subscribe" { box.withLock { $0 }?.disconnectClient() }
            return []
        }
        box.withLock { $0 = server }
        defer { server.stop() }
        let transport = try LineTransport(path: server.path)
        transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        let results = await transport.pipeline([PipelinedLine(IdentifyRequest()), PipelinedLine(SubscribeRequest(treeEvents: .deltas))],
                                               timeout: .seconds(30))
        #expect(results.count == 2)
        for result in results {
            #expect(throws: DaemonError.self) { try result.get() }
        }
    }

    @Test func aWrongAppIsRejectedAfterTheGroupWasSent() async throws {
        let server = try FakeDaemonServer { request in
            let id = request["id"]?.intValue ?? 0
            let body = request["cmd"]?.stringValue == "identify"
                ? ConnectionTests.identify.replacingOccurrences(of: #""app":"cmux-tui""#, with: #""app":"other""#) : "{}"
            return [#"{"id":\#(id),"ok":true,"data":\#(body)}"#]
        }
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path), configuration: Self.quick)
        await #expect(throws: DaemonError.wrongApp("other")) { try await connection.start() }
        #expect(await !connection.isReady)
    }
}
