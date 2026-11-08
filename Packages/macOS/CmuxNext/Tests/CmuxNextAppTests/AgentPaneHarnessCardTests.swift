@testable import CmuxNextAgentPane
import Darwin
import Foundation
import Testing

/// The agent CLI card's Restart Chat (cx-1mbnu) restarts only a chat this pane started or shows:
/// a page that adopts another chat's id (`chat.persistSession`) and then asks for a restart is
/// refused before anything reaches acpmux, so it cannot restart other chats' agents.
@MainActor
struct AgentPaneHarnessCardTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A pane with an acpmux socket that does not answer: a request that reaches it fails as
    /// `harness.failed`, one refused first never gets there.
    private static func pane() -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost())
        model.transport.acpmuxSocket = FileManager.default.temporaryDirectory.appending(path: "no-acpmux-\(UUID().uuidString).sock").path
        return model
    }

    private static func restart(_ model: AgentPaneModel, adopting id: String) async -> String? {
        _ = await model.respond(to: AgentPaneRequest(body: ["method": "chat.persistSession", "params": ["sessionId": id]]))
        model.transport.gestures.record()
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "harness.restart", "params": [:]]))
        return (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func restartOfAChatThePaneDoesNotShowIsRefused() async {
        #expect(await Self.restart(Self.pane(), adopting: "someone-elses-chat") == "harness.not_this_chat")
    }

    @Test func restartOfThePanesOwnChatGoesToAcpmux() async {
        let model = Self.pane()
        model.transport.sessions.add("this-chat")
        #expect(await Self.restart(model, adopting: "this-chat") == "harness.failed")
    }

    // MARK: An agent service older than the app

    /// A host whose restart of an outdated agent service answers `restarted` (the new daemon's socket,
    /// nil when it could not restart), counting its calls.
    private actor RestartingHost: AgentPaneHostProviding {
        let restarted: String?
        private(set) var restarts = 0
        init(restarted: String?) { self.restarted = restarted }
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
        func restartOutdatedAcpmux(sessionId: String?) async -> String? {
            restarts += 1
            return restarted
        }
    }

    private static func update(_ model: AgentPaneModel) async -> [String: Any] {
        model.transport.gestures.record()
        return await model.respond(to: AgentPaneRequest(body: ["method": "harness.update", "params": ["id": "claude"]]))
    }

    /// An agent service that lacks the request is restarted by the app and asked once more: the
    /// card gets the new service's answer, not "Quit and reopen cmux".
    @Test func anOutdatedServiceIsRestartedAndTheUpdateGoesThrough() async throws {
        let old = try OneAnswerAcpmux(reply: ["error": ["code": -32601, "message": "Method not found"]])
        let new = try OneAnswerAcpmux(reply: ["result": ["results": [["id": "claude", "ok": true, "version": "2.0"]]]])
        let host = RestartingHost(restarted: new.path)
        let model = AgentPaneModel(host: host)
        model.transport.acpmuxSocket = old.path
        let reply = await Self.update(model)
        #expect(reply["error"] == nil, "\(reply)")
        let value = reply["value"] as? [String: Any] ?? [:]
        #expect(value["ok"] as? Bool == true, "\(reply)")
        #expect(value["version"] as? String == "2.0", "\(reply)")
        #expect(await host.restarts == 1)
    }

    /// When the app cannot restart the outdated service, the card says so once, with the one step left.
    @Test func anOutdatedServiceThatCannotRestartSaysSo() async throws {
        let old = try OneAnswerAcpmux(reply: ["error": ["code": -32601, "message": "Method not found"]])
        let host = RestartingHost(restarted: nil)
        let model = AgentPaneModel(host: host)
        model.transport.acpmuxSocket = old.path
        let reply = await Self.update(model)
        let error = reply["error"] as? [String: Any]
        #expect(error?["code"] as? String == "harness.failed", "\(reply)")
        #expect(error?["userMessage"] as? String == AgentPaneHarnessCard.oldServiceMessage, "\(reply)")
        #expect(await host.restarts == 1)
    }

    /// Any other failure never restarts the service.
    @Test func anotherFailureRestartsNothing() async throws {
        let old = try OneAnswerAcpmux(reply: ["error": ["code": -32000, "message": "the updater failed"]])
        let host = RestartingHost(restarted: "/nonexistent")
        let model = AgentPaneModel(host: host)
        model.transport.acpmuxSocket = old.path
        let reply = await Self.update(model)
        #expect((reply["error"] as? [String: Any])?["userMessage"] as? String == "the updater failed", "\(reply)")
        #expect(await host.restarts == 0)
    }

    /// A Chief-owned chat's daemon is the Chief home's: the router never restarts it, even when
    /// that host may start daemons; a local chat's goes to this Mac's host.
    @Test func theRouterNeverRestartsAChiefChatsDaemon() async {
        let local = RestartingHost(restarted: "/tmp/local.sock"), chief = RestartingHost(restarted: "/tmp/chief.sock")
        let router = AcpmuxChiefSessionRouter(local: local, chief: chief, chiefOwns: { $0 == "chief-chat" })
        #expect(await router.restartOutdatedAcpmux(sessionId: "chief-chat") == nil)
        #expect(await router.restartOutdatedAcpmux(sessionId: "local-chat") == "/tmp/local.sock")
        #expect(await chief.restarts == 0)
        #expect(await local.restarts == 1)
    }
}

/// A stand-in acpmux on a unix socket for one request: answers `initialize`, then the request
/// with `reply` (its `result` or `error`). One client.
nonisolated final class OneAnswerAcpmux {
    let path: String
    private let listener: Int32

    init(reply: [String: Any]) throws {
        path = "/tmp/cmux-harness-\(getpid())-\(UInt32.random(in: 0 ... .max)).sock"
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        listener = server
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(server, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
        var answer: [String: Any] = ["jsonrpc": "2.0", "id": 2]
        answer.merge(reply) { $1 }
        let initialized = Self.line(["jsonrpc": "2.0", "id": 1, "result": ["protocolVersion": 1]])
        let answered = Self.line(answer)
        Thread.detachNewThread {
            let fd = accept(server, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // initialize and the request arrive together.
            var seen = 0
            var byte: UInt8 = 0
            while seen < 2, read(fd, &byte, 1) == 1 { if byte == 0x0A { seen += 1 } }
            let data = initialized + answered
            _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            // Keep the connection until the client closes it.
            while read(fd, &byte, 1) == 1 {}
            close(fd)
        }
    }

    deinit {
        close(listener)
        unlink(path)
    }

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }
}
