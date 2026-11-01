import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
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

    /// A chat with no folder of its own starts in the machine's work folder, as its daemon lists
    /// it (`agent-session-folders`), never the refusal "open a terminal there first".
    @Test func aChatWithNoFolderStartsInTheMachinesWorkFolder() async throws {
        let request = try await start(harness: nil, model: nil, seedCwd: nil, expectedCwd: "/home/cmux/work")
        #expect(request["harness"] as? String == "claude")
    }

    @Test func aModernCloudDaemonReceivesNoFolderForRustToChoose() async throws {
        let request = try await start(harness: nil, model: nil, seedCwd: nil, expectedCwd: nil, supportsNoCwd: true)
        #expect(request["cwd"] == nil)
    }

    @Test func theFolderListIsTheWorkspacesThenTheMachinesEachOnce() {
        let folders = AgentTabRemoteStart.folders(listed: ["/srv/app", "/home/cmux/work"],
                                                  machine: ["/home/cmux/work", "/home/cmux/work/repo"])
        #expect(folders == ["/srv/app", "/home/cmux/work", "/home/cmux/work/repo"])
    }

    /// A teammate's Cloud machine (its link's `vm_kind: "team"`): the start is refused as a
    /// teammate's machine, so the card offers New Cloud Machine, and nothing reaches the machine
    /// (cmux#29214). The endpoint would fail the test if it were ever asked.
    @Test func aTeammatesMachineRefusesAsATeamMachineAndSendsNothing() async throws {
        let (tabs, key) = try makeTabs(seedCwd: "/home/dev/project")
        await #expect(throws: AgentRemoteStartRefusal.teamMachine(machine: "Team fixture")) {
            _ = try await tabs.startRemoteChat(key, machine: "Team fixture", ownerLink: { nil }, teammate: { true },
                                               endpoint: { Issue.record("a teammate's machine was dialed"); throw CancellationError() })
        }
        #expect(tabs.sessions[key] == nil)
    }

    /// The linked Mac still has its old attach-time owner answer, but the owner has revoked the
    /// teammate's chat-start grant. A *new* chat must never reach the remote daemon on that lease.
    @Test func revokingAChatGrantRefusesAnotherStartOnAnAlreadyOpenLink() async throws {
        let (tabs, key) = try makeTabs(seedCwd: "/home/dev/project")
        await #expect(throws: AgentRemoteStartRefusal.teamMachine(machine: "Shared VM")) {
            _ = try await tabs.startRemoteChat(key, machine: "Shared VM", ownerLink: { 17 },
                                               verifyChatStart: { false }, teammate: { false },
                                               endpoint: { Issue.record("a revoked grant started another chat"); throw CancellationError() })
        }
        #expect(tabs.sessions[key] == nil)
    }

    /// An unavailable role/grant check must fail closed even if the old link still says owner.
    @Test func anUnreadableGrantRefusesAnotherStartWithoutDialing() async throws {
        let (tabs, key) = try makeTabs(seedCwd: "/home/dev/project")
        await #expect(throws: AgentRemoteStartRefusal(code: "agent_session.host_unverified", machine: "Shared VM")) {
            _ = try await tabs.startRemoteChat(key, machine: "Shared VM", ownerLink: { 17 },
                                               verifyChatStart: { throw URLError(.timedOut) }, teammate: { false },
                                               endpoint: { Issue.record("the permission check failed but a start was dialed"); throw CancellationError() })
        }
        #expect(tabs.sessions[key] == nil)
    }

    @Test func anExistingGrantCanStillStartAfterAFreshAuthorizationCheck() async throws {
        let request = try await start(harness: nil, model: nil, verifyChatStart: { true })
        #expect(request["vm_kind"] as? String == "owner")
    }

    /// Only an owner check's refusal becomes the teammate one, and only on a teammate's link; the
    /// owner check itself is never skipped (`host_unverified` stays for a machine of no known kind).
    @Test func onlyAnUnverifiedOwnerOnATeammatesLinkIsATeamRefusal() {
        #expect(AgentSessionAttachError.classified("agent_session.host_unverified", teammate: true) == "agent_session.team_vm_blocked")
        #expect(AgentSessionAttachError.classified("agent_session.host_unverified", teammate: false) == "agent_session.host_unverified")
        #expect(AgentSessionAttachError.classified("agent_session.timeout", teammate: true) == "agent_session.timeout")
        #expect(AgentRemoteStartRefusal.teamMachine(machine: "vm").userMessage.contains("teammate"))
    }

    /// A link's `vm_kind: "team"` answer names the machine a teammate's; an owner answer never does.
    @Test func aTeamAnswerIsATeammatesLinkAndAnOwnerAnswerIsNot() {
        let key = CloudLinkKey(machine: "vm")
        #expect(CloudLinkSocket(key: key, path: "/tmp/s", generation: nil, callerIsTeammate: true).callerIsTeammate)
        #expect(!CloudLinkSocket(key: key, path: "/tmp/s", generation: nil, callerOwnsVM: true, callerIsTeammate: true).callerIsTeammate)
        #expect(!CloudLinkSocket(key: key, path: "/tmp/s", generation: nil).callerIsTeammate)
    }

    private func makeTabs(seedCwd: String?) throws -> (AgentTabStore, String) {
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
        tabs.remoteSeeds[key] = AgentPaneSeedSource(AgentPaneSeed(cwd: seedCwd, harness: "claude", model: "claude-seed-model"))
        return (tabs, key)
    }

    /// Exercise the tab store's first-Send route through the real attach client, including
    /// capability negotiation, and inspect the frame received by the remote daemon.
    private func start(harness: String?, model: String?, seedCwd: String? = "/home/dev/project",
                       expectedCwd: String? = "/home/dev/project", supportsNoCwd: Bool = false,
                       verifyChatStart: (@Sendable () async throws -> Bool)? = nil) async throws -> [String: Any] {
        let (tabs, key) = try makeTabs(seedCwd: seedCwd)
        let daemon = try RemoteStartDaemon(supportsNoCwd: supportsNoCwd)
        async let received = daemon.firstStart()
        let started = try await tabs.startRemoteChat(key, machine: "Cloud fixture", harness: harness, model: model,
                                                    ownerLink: { 1 }, verifyChatStart: verifyChatStart,
                                                    endpoint: { DaemonEndpoint(socketPath: daemon.path) })
        #expect(started == AgentTabRemoteStart.Started(surface: 7, session: "remote-session"))
        #expect(tabs.sessions[key] == "remote-session")
        let data = try await received
        let request = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request["surface"] as? Int == 7)
        #expect(request["cwd"] as? String == expectedCwd)
        #expect(request["vm_kind"] as? String == "owner")
        return request
    }
}

/// Bounded socket connections (a folder lookup's, then the start's), answering the handshake, the
/// machine's folders and a successful remote start.
/// Blocking socket reads run on a dedicated thread; only received bytes cross back to the test.
private nonisolated final class RemoteStartDaemon: Sendable {
    let path: String
    let supportsNoCwd: Bool
    private let descriptor: Int32

    init(supportsNoCwd: Bool = false) throws {
        self.supportsNoCwd = supportsNoCwd
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
        let noCwdCapability = self.supportsNoCwd
        let line: Data? = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let line = Self.serve(descriptor, until: Date().addingTimeInterval(20), supportsNoCwd: noCwdCapability)
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

    private static func serve(_ listener: Int32, until deadline: Date, supportsNoCwd: Bool) -> Data? {
        while readable(listener, until: deadline) {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return nil }
            if let line = serveClient(client, until: deadline, supportsNoCwd: supportsNoCwd) { return line }
        }
        return nil
    }

    /// One connection until it closes (nil) or sends its start (that line).
    private static func serveClient(_ client: Int32, until deadline: Date, supportsNoCwd: Bool) -> Data? {
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
                    var capabilities = [
                        "agent-session-attach-v1", "agent-session-start-v1",
                        "agent-session-start-model-v1", "agent-session-start-vm-kind-v1", "agent-session-folders-v1",
                    ]
                    if supportsNoCwd { capabilities.append("agent-session-start-no-cwd-v1") }
                    data = ["app": "cmux-tui", "protocol": 12, "generation": "remote-start-fixture", "capabilities": capabilities]
                case "agent-session-folders": data = ["default": "/home/cmux/work", "folders": ["/home/cmux/work"]]
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
