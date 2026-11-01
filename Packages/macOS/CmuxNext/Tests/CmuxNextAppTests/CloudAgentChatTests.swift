import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// An ACP chat in a Cloud workspace runs its agent on the machine (#25583), at the app boundary.
/// This Mac is a real cmux-tui daemon; the Cloud machine is a second real daemon reached the way
/// the app reaches a machine's link socket (`DaemonService.start(remote:)` on a
/// ``CloudMachineSession``), whose own acpmux runs the test agent (acpmux's `fake_agent.py`, the
/// `sample` harness of `cmux harness add sample`). A person's New Agent Chat in that machine's
/// workspace opens the tab on the machine's store; the page's frames go through the tab's real
/// pane host (``AgentTabRemoteHost``) and wire (``RemoteAcpmuxWire``) as the agent pane sends
/// them. The Rust suite (cmux-tui tests/cli/agent_session_start.rs) covers the daemon verb alone.
@MainActor @Suite(.serialized, .ownsSidebarDocStore, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CloudAgentChatTests {
    /// The first send starts the chat in the machine's acpmux, in the machine's folder: the
    /// folder trust question goes to that machine and its answer is recorded there, the machine's
    /// store binds the session to the tab, and a prompt from this Mac is answered by the agent
    /// running on the machine. Nothing runs on the machine before that send.
    @Test func aNewChatInACloudWorkspaceRunsItsAgentOnTheMachine() async throws {
        try await Self.withMachine { world in
            let chat = try await world.openChat()
            #expect(chat.record.host == "registry:" + world.machineStore, "the chat is not filed under the machine's store")
            #expect(chat.record.session == nil, "a chat started before its first send")
            #expect(world.agentSessions().isEmpty, "the machine's acpmux runs a chat before the first send")

            let page = try await world.page(chat.key)
            #expect(page.machineName == "Move VM", "the composer's machine chip does not name the Cloud machine")
            let wire = try #require(page.wire, "the chat has no remote route")
            let frames = try await Frames.open(wire)
            _ = try await frames.call(wire, "initialize", ["protocolVersion": 1])
            let watched = try await frames.call(wire, "_acpmux/watch", [:])
            #expect((watched.result?["sessions"] as? [Any])?.isEmpty == true)

            // The first send in an untrusted folder of the machine is the page's trust question.
            let newChat: [String: Any] = ["cwd": world.work.path, "mcpServers": [Any](), "_meta": ["acpmux": ["harness": "sample"]]]
            let untrusted = try await frames.call(wire, "session/new", newChat)
            #expect(untrusted.errorCode == "agent_session.untrusted_folder", "\(untrusted.raw)")
            #expect(untrusted.errorData?["reason"] as? String == "trust.pending")
            #expect(untrusted.errorData?["cwd"] as? String == world.work.path)
            let trusted = try await frames.call(wire, "acp.trust.set", ["cwd": world.work.path, "level": "trusted"])
            #expect(trusted.errorCode == nil, "\(trusted.raw)")

            let started = try await frames.call(wire, "session/new", newChat)
            let session = try #require(started.result?["sessionId"] as? String, "the chat did not start: \(started.raw)")
            #expect(world.agentSessions() == [session], "the session does not run in the machine's acpmux")
            let bound = await world.until { world.machineTab(chat.surface)?.agentSession?.session == session }
            #expect(bound, "the machine's store did not bind the started session to the chat's tab")

            _ = try await frames.call(wire, "_acpmux/attach", ["sessionId": session])
            // The test agent answers `envs:` with its own environment: the machine's home folder
            // proves the agent process runs on the machine, not on this Mac (acpmux gives its
            // agents no ACPMUX_HOME, so only HOME tells).
            let prompt = "envs:HOME"
            let sent = try await frames.call(wire, "session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": prompt]]])
            #expect(sent.errorCode == nil, "\(sent.raw)")
            let machineEnvironment = { (frames: Frames) in
                frames.agentText().contains { $0.contains(#""HOME": "\#(world.home.path)""#) }
            }
            let answered = await world.until { machineEnvironment(frames) }
            #expect(answered, "the machine's agent did not answer with the machine's environment: \(frames.agentText())")
            wire.cancel(code: 1000, reason: "test")

            // The page's next connection (a reload, the tab shown again) attaches to that chat on
            // the machine and replays it; it never starts another.
            let again = try await world.page(chat.key)
            let rewire = try #require(again.wire, "the started chat has no remote route")
            let replay = try await Frames.open(rewire)
            let attached = try await replay.call(rewire, "_acpmux/attach", ["sessionId": session])
            #expect(attached.errorCode == nil, "\(attached.raw)")
            let replayed = await world.until { machineEnvironment(replay) }
            #expect(replayed, "the reconnected page does not replay the machine's chat")
            #expect(world.agentSessions() == [session], "a reconnect started another chat on the machine")
            rewire.cancel(code: 1000, reason: "test")
        }
    }

    /// The GUI's default first send: the page names no folder (a fresh Cloud workspace's New Tab
    /// page has none of its own), so the chat starts in the folder the machine's workspace
    /// reports there, and once the person trusts it the agent runs on the machine.
    @Test func aFirstSendWithNoFolderStartsInTheWorkspacesFolderOnTheMachine() async throws {
        try await Self.withMachine { world in
            let chat = try await world.openChat()
            let wire = try #require(try await world.page(chat.key).wire)
            let frames = try await Frames.open(wire)
            let newChat: [String: Any] = ["mcpServers": [Any](), "_meta": ["acpmux": ["harness": "sample"]]]
            let first = try await frames.call(wire, "session/new", newChat)
            #expect(first.errorCode == "agent_session.untrusted_folder", "the default first send: \(first.raw)")
            // The folder the machine's workspace reports there (its terminal's), never one of this Mac.
            let folder = try #require(first.errorData?["cwd"] as? String, "\(first.raw)")
            #expect(folder == world.workspace.firstTabFolder, "the chat's folder is not its workspace's on the machine")
            #expect(folder == world.work.path, "the chat's folder is not the machine's work folder")
            let trusted = try await frames.call(wire, "acp.trust.set", ["cwd": folder, "level": "trusted"])
            #expect(trusted.errorCode == nil, "\(trusted.raw)")
            let started = try await frames.call(wire, "session/new", newChat)
            #expect(started.result?["sessionId"] is String, "\(started.raw)")
            #expect(world.agentSessions().count == 1)
            wire.cancel(code: 1000, reason: "test")
        }
    }

    /// The Cloud API gives the creator an owner answer on a team machine too (#28788). Its
    /// own work folder needs no trust question (#29556), so the owner's first send starts there.
    @Test func aTeamMachinesOwnerStartsTheChatInItsWorkFolder() async throws {
        try await Self.withMachine(hostKind: "team-vm", workFolder: "work") { world in
            let chat = try await world.openChat()
            let wire = try #require(try await world.page(chat.key).wire)
            let frames = try await Frames.open(wire)
            let started = try await frames.call(wire, "session/new", ["cwd": world.work.path, "mcpServers": [Any](),
                                                                      "_meta": ["acpmux": ["harness": "sample"]]])
            let session = try #require(started.result?["sessionId"] as? String, "the owner's chat did not start: \(started.raw)")
            #expect(world.agentSessions() == [session])
            let bound = await world.until { world.machineTab(chat.surface)?.agentSession?.session == session }
            #expect(bound, "the machine's store did not bind its owner's chat")
            wire.cancel(code: 1000, reason: "test")
        }
    }

    /// A Cloud machine whose link gave no owner answer (the API said nothing, or no link runs):
    /// the app sends no start there, whatever the machine's own record says (#26323),
    /// and the page says the machine could not be confirmed. No agent runs there.
    @Test(arguments: [nil, "team-vm"] as [String?])
    func noOwnerAnswerOnTheLinkStartsNoChat(hostKind: String?) async throws {
        // On a plain host the daemon allows any start, so only the app refuses it. A team
        // machine without an owner answer must also stay idle, regardless of its own record.
        try await Self.withMachine(hostKind: hostKind, ownerLink: false) { world in
            let chat = try await world.openChat()
            let wire = try #require(try await world.page(chat.key).wire)
            let frames = try await Frames.open(wire)
            let refused = try await frames.call(wire, "session/new", ["cwd": world.work.path, "mcpServers": [Any](),
                                                                      "_meta": ["acpmux": ["harness": "sample"]]])
            #expect(refused.errorCode == "agent_session.host_unverified", "\(refused.raw)")
            #expect(refused.errorMessage == AgentRemoteStartRefusal(code: "agent_session.host_unverified", machine: "Move VM").userMessage)
            #expect(world.agentSessions().isEmpty)
            let tab = try #require(world.machineTab(chat.surface), "the machine's store does not list the chat")
            #expect(tab.agentSession?.session == nil)
            wire.cancel(code: 1000, reason: "test")
        }
    }

    // MARK: World

    /// This Mac's app, connected to a Cloud machine with a workspace there.
    final class World {
        let services: AppServices
        let machine: CloudMachineSession
        let workspace: WorkspaceModel
        /// The machine's work folder (under its home), where its workspace's terminal starts.
        let work: URL
        /// The machine's home folder (its daemon's and agents' `HOME`).
        let home: URL
        let acpmuxHome: URL
        let binary: URL

        init(services: AppServices, machine: CloudMachineSession, workspace: WorkspaceModel, work: URL, home: URL, acpmuxHome: URL, binary: URL) {
            self.services = services
            self.machine = machine
            self.workspace = workspace
            self.work = work
            self.home = home
            self.acpmuxHome = acpmuxHome
            self.binary = binary
        }

        /// The machine's store id, as a chat filed under it names it.
        var machineStore: String {
            (AgentTabStore.registryHost(of: machine.daemon) ?? "").replacingOccurrences(of: "registry:", with: "")
        }

        struct Chat {
            let key: String
            let surface: UInt64
            let record: AgentSessionRef
        }

        /// A person's New Agent Chat in the machine workspace's pane: the tab the app opens there,
        /// once the machine's store lists it.
        func openChat() async throws -> Chat {
            let pane = try #require(workspace.screens.flatMap(\.panes).first, "the machine's workspace has no pane")
            let created = try await services.agentTabs.open(in: pane.handle, of: machine.daemon).value()
            let listed = await until { self.services.locateTab(created.key) != nil }
            try #require(listed, "the machine's store did not list the new chat")
            let (tab, _) = try #require(services.locateTab(created.key))
            let record = try #require(tab.agentSession, "the new tab is not an agent chat")
            return Chat(key: created.key, surface: tab.surface.rawValue, record: record)
        }

        /// The chat's pane host as the agent pane gets it, and its handshake.
        func page(_ key: String) async throws -> (machineName: String?, wire: (any AcpmuxPaneWire)?) {
            let host = try #require(services.agentTabs.remoteHost(key), "the chat has no pane host")
            #expect(host is AgentTabRemoteHost, "the chat's host is \(type(of: host)), not the machine's")
            let handshake = try await host.handshake(sessionId: nil)
            return (handshake.machineName, handshake.connection?.remote?.makeWire())
        }

        /// The machine's tab on `surface`, as its store lists it.
        func machineTab(_ surface: UInt64) -> TabModel? {
            machine.daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.surface.rawValue == surface }
        }

        /// The sessions the machine's acpmux holds (`cmux acp --json ls` on its home). No acpmux
        /// socket is none; an answer that is not a session list is an issue, never an empty list.
        func agentSessions() -> [String] {
            guard FileManager.default.fileExists(atPath: acpmuxHome.appendingPathComponent("acpmux.sock").path) else { return [] }
            let output = CloudAgentChatTests.run(binary, ["acp", "--json", "ls"], environment: ["ACPMUX_HOME": acpmuxHome.path])
            let object = (try? JSONSerialization.jsonObject(with: output)) as Any
            guard let list = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["sessions"] as? [[String: Any]]) else {
                Issue.record("`cmux acp --json ls` gave no session list: \(String(decoding: output, as: UTF8.self))")
                return []
            }
            return list.compactMap { ($0["sessionId"] ?? $0["id"]) as? String }
        }

        /// True once `condition` holds, false after 30 seconds.
        func until(_ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(30)
            while !condition(), ContinuousClock.now < deadline, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            return condition()
        }
    }

    /// The frames a wire sends back, and the page's calls on it.
    nonisolated final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [String] = []
        private var next = 0

        var lines: [String] { lock.withLock { received } }

        @MainActor static func open(_ wire: any AcpmuxPaneWire) async throws -> Frames {
            let frames = Frames()
            try await wire.open(onFrame: { [frames] text in frames.lock.withLock { frames.received.append(text) } }, onClose: { _, _ in })
            return frames
        }

        struct Reply {
            let raw: String
            let object: [String: Any]
            var result: [String: Any]? { object["result"] as? [String: Any] }
            var error: [String: Any]? { object["error"] as? [String: Any] }
            var errorData: [String: Any]? { error?["data"] as? [String: Any] }
            var errorCode: String? { errorData?["code"] as? String }
            var errorMessage: String? { error?["message"] as? String }
        }

        /// `method` as the page sends it; its reply, once the wire answered (60 s at most).
        @MainActor func call(_ wire: any AcpmuxPaneWire, _ method: String, _ params: [String: Any]) async throws -> Reply {
            let id = lock.withLock { next += 1; return next }
            let frame = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            wire.send(String(decoding: frame, as: UTF8.self)) { _ in }
            let deadline = ContinuousClock.now + .seconds(60)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                for line in lines {
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                          (object["id"] as? Int) == id, object["method"] == nil else { continue }
                    return Reply(raw: line, object: object)
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("\(method) request \(id) got no answer in 60 s; recent frames: \(lines.suffix(4))")
            throw CancellationError()
        }

        /// What the chat's agent said so far: the text of each `agent_message_chunk` update in the
        /// frames, live or replayed (the wire serves that one session), never the person's prompt.
        func agentText() -> [String] {
            func chunks(_ value: Any) -> [String] {
                if let object = value as? [String: Any] {
                    if object["sessionUpdate"] as? String == "agent_message_chunk",
                       let text = (object["content"] as? [String: Any])?["text"] as? String { return [text] }
                    return object.values.flatMap(chunks)
                }
                return (value as? [Any])?.flatMap(chunks) ?? []
            }
            return lines.flatMap { line in (try? JSONSerialization.jsonObject(with: Data(line.utf8))).map(chunks) ?? [] }
        }
    }

    // MARK: Setup

    /// Runs `body` with this Mac's app connected to a Cloud machine whose daemon's acpmux runs the
    /// test agent. `hostKind`: the machine kind its daemon is told (`CMUX_AGENT_START_HOST`, which
    /// can only make it stricter); the default `unknown-cloud` is a Cloud machine with no record of
    /// its own, as an owner's machine is to its daemon, so a start or a trust answer runs there only
    /// with the app's `vm_kind: "owner"`; nil is a plain host (its daemon allows any start).
    /// `ownerLink`: the machine's link runs and its attach answer says the signed-in caller owns the
    /// machine (`vmKind: "owner"`), as the Cloud API answers for a person's own machine; false, no
    /// link runs (no owner answer).
    private static func withMachine(hostKind: String? = "unknown-cloud", ownerLink: Bool = true, workFolder: String = "project", _ body: (World) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { repo.deleteLastPathComponent() }
        let agent = repo.appendingPathComponent("cmux-tui/crates/acpmux/tests/fake_agent.py")
        try #require(FileManager.default.fileExists(atPath: agent.path), "no test agent at \(agent.path)")
        // A real path (no /tmp symlink): the daemon reports a terminal's folder as it launched it.
        let root = URL(fileURLWithPath: "/private/tmp/cn-chat-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let macHome = root.appendingPathComponent("mac-home", isDirectory: true)
        let home = root.appendingPathComponent("vm-home", isDirectory: true)
        // HOME/work is automatically trusted for an owner. A project folder keeps the first
        // two tests on the explicit trust path; the owner-on-team test selects work itself.
        let work = home.appendingPathComponent(workFolder, isDirectory: true)
        let acpmuxHome = root.appendingPathComponent("vm-acpmux", isDirectory: true)
        try FileManager.default.createDirectory(at: macHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: acpmuxHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The machine's acpmux: one harness, the sample one (an asking mode, so it may run from here).
        let config: [String: Any] = [
            "harnesses": ["sample": ["argv": ["env", "FAKE_ASK_MODE=1", "python3", agent.path], "family": "sample"]],
            "defaultHarness": "sample",
            "webAskingModes": ["sample": ["ask"]],
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: acpmuxHome.appendingPathComponent("config.json"))

        // Only the explicit sample harness: a login shell can change PATH, and live catalog
        // fetches and probes make this fixture depend on the worker's setup and network.
        let base = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color",
                    "ACPMUX_LOGIN_ENV": "0", "ACPMUX_CATALOG_FETCH": "0", "ACPMUX_REGISTRY_FETCH": "0",
                    "ACPMUX_HEALTH_FETCH": "0", "ACPMUX_PROBE_HARNESSES": ""]
        // This Mac's acpmux has a home of its own: a chat that ran here instead never touches the person's.
        let macAcpmux = root.appendingPathComponent("mac-acpmux").path
        let macEnvironment: @Sendable () -> [String: String] = { base.merging(["HOME": macHome.path, "ACPMUX_HOME": macAcpmux]) { $1 } }
        var vmVariables = base.merging(["HOME": home.path, "ACPMUX_HOME": acpmuxHome.path]) { $1 }
        if let hostKind { vmVariables["CMUX_AGENT_START_HOST"] = hostKind }
        let vmEnvironment: @Sendable () -> [String: String] = { [vmVariables] in vmVariables }
        // Both owners end with this test process, so a crashed or cancelled run leaves no daemon behind.
        let pid = ProcessInfo.processInfo.processIdentifier
        let mac = DaemonLauncher(configuration: .init(binary: binary, session: "cn-chat-mac-\(UUID().uuidString.prefix(6).lowercased())",
                                                      stateDirectory: root.appendingPathComponent("mac-state"), exitWithProcess: pid),
                                 environment: macEnvironment)
        let vm = DaemonLauncher(configuration: .init(binary: binary, session: "cn-chat-vm-\(UUID().uuidString.prefix(6).lowercased())",
                                                     stateDirectory: root.appendingPathComponent("vm-state"), exitWithProcess: pid),
                                environment: vmEnvironment)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        var cloudMachine: CloudMachineSession?
        var hub: CloudTunnelHub?

        let result: Result<Void, any Error>
        do {
            let vmSocket = try await vm.endpointProvider().socketPath
            services.daemon.start {
                DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: mac.endpointProvider)
            }
            services.windows.restoreWhenLoaded()
            let (machine, machineHub) = try Self.machine(root: root)
            cloudMachine = machine
            hub = machineHub
            services.machines.add(machine)
            machine.daemon.start(remote: { vmSocket })
            // The link's attach answer: the app starts a chat on a Cloud machine only on its owner word.
            if ownerLink {
                _ = try await machine.link?.socketPath()
                try #require(await machine.link?.ownerLink != nil, "the machine's link gave no owner answer")
            }

            let deadline = ContinuousClock.now + .seconds(60)
            func ready() -> Bool {
                services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } }
                    && machine.daemon.connection != nil && AgentTabStore.registryHost(of: machine.daemon) != nil
            }
            while !ready(), ContinuousClock.now < deadline, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            try #require(ready(), "the daemons did not come up")
            let connection = try #require(machine.daemon.connection)
            // The Cloud workspace, with its terminal in the machine's work folder (so a pane there),
            // as a person's new workspace opened on a folder of the machine.
            let key = WorkspaceKey.generate()
            try await connection.createWorkspace(name: "Cloud", key: key)
            try await connection.createTerminal(in: key, cwd: work.path)
            func target() -> WorkspaceModel? {
                machine.daemon.store.workspaces.first { $0.key == key && $0.screens.contains { !$0.panes.isEmpty } }
            }
            while target() == nil, ContinuousClock.now < deadline, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            let workspace = try #require(target(), "the machine's workspace has no pane")
            try await body(World(services: services, machine: machine, workspace: workspace, work: work, home: home, acpmuxHome: acpmuxHome, binary: binary))
            result = .success(())
        } catch {
            let log = await Task.detached {
                (try? Data(contentsOf: acpmuxHome.appendingPathComponent("daemon.log"))).map {
                    String(decoding: $0.suffix(8192), as: UTF8.self)
                } ?? "no machine acpmux log"
            }.value
            print("CloudAgentChatTests machine acpmux on failure: \(log)")
            result = .failure(error)
        }
        await CloudMoveTests.end(services.daemon)
        if let cloudMachine {
            await CloudMoveTests.end(cloudMachine.daemon)
            await cloudMachine.link?.stop()
        }
        await hub?.stop()
        _ = run(binary, ["acp", "daemon", "shutdown", "--end-agents"], environment: ["ACPMUX_HOME": acpmuxHome.path, "HOME": home.path])
        // A chat that wrongly ran on this Mac would have started its acpmux here.
        _ = run(binary, ["acp", "daemon", "shutdown", "--end-agents"], environment: ["ACPMUX_HOME": macAcpmux, "HOME": macHome.path])
        for controller in services.windows.controllers { controller.window?.close() }
        try result.get()
    }

    /// The Cloud machine "Move VM", whose daemon each test starts on the second daemon's socket.
    /// Its link is a stand-in `cmux-tui` (`wg hub` ready, `remote connect` connected) over the
    /// `/api/vm` stand-in, whose attach answer says the caller owns the machine
    /// (``CloudLinkReconnectingTests/StandInVMAPI``); it carries no traffic, only that answer.
    static func machine(root: URL) throws -> (CloudMachineSession, CloudTunnelHub) {
        let tui = root.appendingPathComponent("link-tui")
        try """
            #!/bin/sh
            case "$1" in
            wg)
              while [ $# -gt 0 ]; do [ "$1" = --socket ] && H=$2; shift; done
              : > "$H"
              printf '{"event":"hub-ready","socket":"%s","routes":[]}\\n' "$H"
              exec sleep 600 ;;
            remote)
              while [ $# -gt 0 ]; do [ "$1" = --local-socket ] && S=$2; shift; done
              : > "$S"
              printf '{"event":"connection-snapshot","local_socket":"%s","connection":{"session_id":"s","generation":1,"state":"connected","lane_bindings":[],"physical_link_count":1,"transport":{"provider":"cloud","route":"ws://10.9.0.2:1337/v1/link"}}}\\n' "$S"
              exec sleep 600 ;;
            esac
            exit 64

            """.write(to: tui, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tui.path)
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "http://vm-api.standin.invalid"],
                                                       process: [:], isDebugBuild: true)
        let urlSession = URLSessionConfiguration.ephemeral
        urlSession.protocolClasses = [CloudLinkReconnectingTests.StandInVMAPI.self]
        let api = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { nil },
                                 session: URLSession(configuration: urlSession))
        let paths = CloudPaths(root: root.appendingPathComponent("cloud", isDirectory: true))
        let hub = CloudTunnelHub(api: api, paths: paths, binary: tui, deviceName: "cn-chat-test")
        let link = CloudMachineLink(machineID: "vm-move", api: api, hub: hub, paths: paths, binary: tui, deviceName: "cn-chat-test")
        let session = CloudMachineSession(machine: CloudMachine(id: "vm-move", displayName: "Move VM"), link: link,
                                          mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        return (session, hub)
    }

    /// `binary arguments` with `environment` over a plain PATH; its standard output.
    nonisolated static func run(_ binary: URL, _ arguments: [String], environment: [String: String]) -> Data {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Data() }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return output
    }
}
