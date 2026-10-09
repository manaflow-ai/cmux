import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// `AgentSessionAttachClient` against a scripted daemon: its own connection with the
/// capability check, verbs that name only the tab's surface (never a session), pushes of that tab only, refusal codes, and a dropped connection ending the attachment.
@Suite(.timeLimit(.minutes(1))) struct AgentSessionAttachClientTests {
    static let identify = ConnectionTests.identify.replacingOccurrences(
        of: #""attach-initial-size""#, with: #""attach-initial-size","agent-session-attach-v1""#)

    final class Log: Sendable {
        let requests = Mutex<[[String: JSONValue]]>([])
        func append(_ request: [String: JSONValue]) { requests.withLock { $0.append(request) } }
        func all(_ cmd: String) -> [[String: JSONValue]] { requests.withLock { $0.filter { $0["cmd"]?.stringValue == cmd } } }
    }

    final class Events: Sendable {
        let items = Mutex<[(String, Data)]>([])
        func append(_ name: String, _ line: Data) { items.withLock { $0.append((name, line)) } }
        var names: [String] { items.withLock { $0.map(\.0) } }
    }

    static func server(identify: String = identify, log: Log) throws -> FakeDaemonServer {
        try FakeDaemonServer { request in
            log.append(request)
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify":
                return [#"{"id":\#(id),"ok":true,"data":\#(identify.replacingOccurrences(of: "GEN", with: "g"))}"#]
            case "set-client-info":
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            case "agent-session-attach":
                return [
                    #"{"id":\#(id),"ok":true,"data":{"session":{"sessionId":"acp_1"},"events":[],"hasMore":false,"lastSeq":4}}"#,
                    #"{"event":"agent-session-record","surface":99,"record":{"seq":7}}"#,
                    #"{"event":"agent-session-record","surface":7,"record":{"seq":5}}"#,
                    #"{"event":"agent-session-permission","surface":7,"request":{"permissionId":"p1"}}"#,
                ]
            case "agent-session-prompt":
                return [#"{"id":\#(id),"ok":false,"error":"no","error_code":"agent_session.not_attached"}"#]
            default:
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        }
    }

    static func client(_ server: FakeDaemonServer) -> AgentSessionAttachClient {
        let path = server.path
        return AgentSessionAttachClient(surface: 7) { DaemonEndpoint(socketPath: path) }
    }

    @Test func attachNamesOnlyTheSurfaceAndStreamsThatTabsPushes() async throws {
        let log = Log()
        let server = try Self.server(log: log)
        let client = Self.client(server)
        let events = Events()
        let page = try await client.attach(afterSeq: 4, beforeSeq: nil, limit: 400, kinds: ["transcript"]) { name, line in
            events.append(name, line)
        }
        let object = try #require(try JSONSerialization.jsonObject(with: page) as? [String: Any])
        #expect(object["lastSeq"] as? Int == 4)
        let sent = try #require(log.all("agent-session-attach").first)
        #expect(sent["surface"] == .number(7))
        #expect(sent["after_seq"] == .number(4))
        #expect(sent["limit"] == .number(400))
        #expect(sent["kinds"] == .array([.string("transcript")]))
        #expect(sent["session"] == nil && sent["sessionId"] == nil, "the daemon pins the session")
        try await waitUntil { events.names.count == 2 }
        #expect(events.names == ["agent-session-record", "agent-session-permission"], "another tab's push is not this tab's")
        await client.close()
    }

    @Test func refusalsKeepTheDaemonCode() async throws {
        let server = try Self.server(log: Log())
        let client = Self.client(server)
        await #expect(throws: AgentSessionAttachError(code: "agent_session.not_attached", message: "no")) {
            _ = try await client.prompt(id: "p1", text: "hi")
        }
        await client.close()
    }

    @Test func aDaemonWithoutTheCapabilityIsRefused() async throws {
        let server = try Self.server(identify: ConnectionTests.identify, log: Log())
        let client = Self.client(server)
        await #expect(throws: AgentSessionAttachError.self) {
            _ = try await client.attach(afterSeq: nil, beforeSeq: nil, limit: nil, kinds: nil) { _, _ in }
        }
    }

    @Test func aDroppedConnectionEndsTheAttachment() async throws {
        let server = try Self.server(log: Log())
        let client = Self.client(server)
        let events = Events()
        _ = try await client.attach(afterSeq: nil, beforeSeq: nil, limit: nil, kinds: nil) { name, line in events.append(name, line) }
        try await waitUntil { events.names.count == 2 }
        server.disconnectClient()
        try await waitUntil { events.names.last == "agent-session-closed" }
        await client.close()
    }

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
