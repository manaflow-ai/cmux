import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// A Cloud chat's seed belongs to its starting harness. A different harness chosen before
/// the first Send must not receive that seed's model when the person keeps its default.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentTabRemoteStartTests {
    @Test func changingHarnessBeforeSendUsesItsDefaultModel() async throws {
        let request = try await start(harness: "codex", model: nil)
        #expect(request["harness"] as? String == "codex")
        #expect(request["model"] == nil, "the Claude seed's model was sent to Codex")
    }

    @Test(arguments: [nil, "claude"] as [String?])
    func keepingTheSeedHarnessKeepsItsModel(harness: String?) async throws {
        let request = try await start(harness: harness, model: nil)
        #expect(request["harness"] as? String == "claude")
        #expect(request["model"] as? String == "claude-seed-model")
    }

    @Test(arguments: [nil, "claude", "codex"] as [String?])
    func anExplicitModelWinsOverTheSeed(harness: String?) async throws {
        let request = try await start(harness: harness, model: "chosen-model")
        #expect(request["harness"] as? String == (harness ?? "claude"))
        #expect(request["model"] as? String == "chosen-model")
    }

    /// Exercise the tab store's first-Send route through the real attach client, including
    /// capability negotiation, and inspect the frame received by the remote daemon.
    private func start(harness: String?, model: String?) async throws -> [String: Any] {
        let store = DaemonStore()
        var tab = TabSnapshot(surface: 7, kind: .conversation, title: "New chat")
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "registry:cloud-fixture", harness: "claude"))
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [tab])])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Project", screens: [screen])]))
        let key = try #require(store.tab(surface: 7)?.id)
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry(), environment: [
            AgentPaneSource.devURLVariable: "http://127.0.0.1:9",
            "CMUX_NEXT_AGENT_PANE_MOCK": "1",
        ], showcase: true)
        tabs.lookup = { key in store.tab(id: key)?.agentSession.map { ($0, store) } }
        tabs.remoteSeeds[key] = AgentPaneSeedSource(AgentPaneSeed(cwd: "/home/dev/project", harness: "claude", model: "claude-seed-model"))

        let daemon = try RemoteStartDaemon()
        async let received = daemon.firstStart()
        let started = try await tabs.startRemoteChat(key, machine: "Cloud fixture", harness: harness, model: model,
                                                    ownerLink: { 1 }, endpoint: { DaemonEndpoint(socketPath: daemon.path) })
        #expect(started == AgentTabRemoteStart.Started(surface: 7, session: "remote-session"))
        #expect(tabs.sessions[key] == "remote-session")
        let data = try await received
        let request = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request["surface"] as? Int == 7)
        #expect(request["cwd"] as? String == "/home/dev/project")
        #expect(request["vm_kind"] as? String == "owner")
        return request
    }
}

/// One bounded socket connection, answering the handshake and a successful remote start.
/// Blocking socket reads run on a dedicated thread; only received bytes cross back to the test.
private nonisolated final class RemoteStartDaemon: Sendable {
    let path: String
    private let descriptor: Int32

    init() throws {
        path = NSTemporaryDirectory() + "remote-start-\(UUID().uuidString.prefix(8)).sock"
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EMFILE) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8.prefix(buffer.count - 1))
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            unlink(path)
            throw POSIXError(.EADDRNOTAVAIL)
        }
    }

    func firstStart() async throws -> Data {
        let descriptor = descriptor
        let path = path
        let line: Data? = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let line = Self.serve(descriptor, until: Date().addingTimeInterval(20))
                // The serving thread alone owns closure. It has already closed its accepted
                // socket before these bytes return; no cleanup retains an fd that can be reused.
                Darwin.close(descriptor)
                unlink(path)
                continuation.resume(returning: line)
            }
        }
        return try #require(line, "agent-session-start never reached the remote daemon")
    }

    private static func readable(_ descriptor: Int32, until deadline: Date) -> Bool {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, Int32(remaining * 1000)) > 0
    }

    private static func serve(_ listener: Int32, until deadline: Date) -> Data? {
        guard readable(listener, until: deadline) else { return nil }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return nil }
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while readable(client, until: deadline) {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = frame["id"], let command = frame["cmd"] as? String else { return nil }
                let data: [String: Any]
                switch command {
                case "identify":
                    data = ["app": "cmux-tui", "protocol": 12, "generation": "remote-start-fixture", "capabilities": [
                        "agent-session-attach-v1", "agent-session-start-v1",
                        "agent-session-start-model-v1", "agent-session-start-vm-kind-v1",
                    ]]
                case "agent-session-start": data = ["session": "remote-session"]
                default: data = [:]
                }
                guard var reply = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "data": data]) else { return nil }
                reply.append(0x0A)
                guard reply.withUnsafeBytes({ send(client, $0.baseAddress, reply.count, 0) }) == reply.count else { return nil }
                if command == "agent-session-start" { return line }
            }
        }
        return nil
    }
}
