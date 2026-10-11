import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// Move to Cloud (cmuxterm-hq#1874 slice 3) at the app boundary: `cmux cloud move` on a live
/// chat tab, sent as the CLI sends it (`action.run`, `cli: true`, origin `cli`, a `tab:` target)
/// to the app's real action registry. This Mac is a real cmux-tui daemon; the Cloud machine is a
/// second real daemon reached the way the app reaches a machine's link socket
/// (`DaemonService.start(remote:)` on a ``CloudMachineSession``). `cmux link sync push` and
/// `cmux link agent move` are a stand-in `cmux` that records its arguments and answers their
/// JSON lines; the Rust suites cover those CLIs against daemons (link_sync.rs,
/// link_agent_move.rs).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CloudMoveTests {
    /// The live chat moves: its folder is synced under the machine's work root, the chat is moved
    /// from this Mac's tab to that folder, and the machine shows it in a Cloud workspace whose
    /// terminal runs in the synced folder. The chat's tab there is bound to the moved session
    /// through the machine's store (so it attaches through that machine and carries its badge),
    /// and this Mac's tab, whose chat closed, is gone.
    @Test func aCLIMoveOfALiveChatEndsWithTheTabAttachedToTheMachineChat() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        // A real path (no /tmp symlink): the daemon reports a terminal's folder as it launched it.
        let root = URL(fileURLWithPath: "/private/tmp/cn-move-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let workRoot = root.appendingPathComponent("vm-home/work", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("cli.log")
        let cli = try Self.standInCLI(in: root, log: log)

        let environment: @Sendable () -> [String: String] = {
            ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"]
        }
        let mac = DaemonLauncher(configuration: .init(binary: binary, session: "cn-move-mac-\(UUID().uuidString.prefix(6).lowercased())",
                                                      stateDirectory: root.appendingPathComponent("mac-state")), environment: environment)
        let vm = DaemonLauncher(configuration: .init(binary: binary, session: "cn-move-vm-\(UUID().uuidString.prefix(6).lowercased())",
                                                     stateDirectory: root.appendingPathComponent("vm-state")), environment: environment)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.cloud.move = CloudMoveSetup(cli: cli, workRoots: [workRoot.path])
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: mac.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        let vmSocket = try await vm.endpointProvider().socketPath
        let machine = Self.machine(services, cli: cli, root: root)
        services.machines.add(machine)
        machine.daemon.start(remote: { vmSocket })

        let result: Result<Moved, any Error>
        do {
            result = .success(try await Self.moveAndRead(services, machine: machine, project: project, log: log))
        } catch {
            result = .failure(error)
        }
        await Self.end(services.daemon)
        await Self.end(machine.daemon)
        for controller in services.windows.controllers { controller.window?.close() }
        let moved = try result.get()

        let synced = workRoot.appendingPathComponent(moved.folderName).path
        #expect(moved.calls.first == ["link", "sync", "push", "--socket", vmSocket, project.path, synced])
        #expect(moved.calls.dropFirst().first == ["link", "agent", "move", "--from-socket", moved.macSocket, "--surface", String(moved.surface),
                                                 "--to-socket", vmSocket, "--cwd", synced])
        #expect(moved.calls.count == 2)
        // The machine shows the chat: bound to the moved session through that machine's store.
        let tab = try #require(moved.machineTab, "no chat tab on the machine")
        #expect(tab.agentSession?.session == "chat-on-vm")
        #expect(tab.agentSession?.host == "registry:" + moved.machineStore)
        #expect(tab.agentSession?.harness == "claude")
        #expect(moved.attachesThroughMachine, "the moved chat does not attach through the machine")
        #expect(moved.badge == "Move VM", "the moved chat's tab carries no Cloud badge")
        #expect(moved.terminalFolders == [synced], "the machine workspace's terminal is not in the synced folder")
        // This Mac's tab is gone (its chat closed with the move).
        #expect(!moved.macStillHasTab)
    }

    struct Moved {
        var calls: [[String]] = []
        var macSocket = ""
        var surface: UInt64 = 0
        var folderName = ""
        var machineStore = ""
        var machineTab: TabModel?
        var attachesThroughMachine = false
        var badge: String?
        var terminalFolders: [String] = []
        var macStillHasTab = true
    }

    /// Opens a live chat in this Mac's first workspace, runs `cmux cloud move` on it and reads
    /// both trees.
    private static func moveAndRead(_ services: AppServices, machine: CloudMachineSession, project: URL, log: URL) async throws -> Moved {
        let deadline = ContinuousClock.now + .seconds(60)
        func ready() -> Bool {
            services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } }
                && machine.daemon.connection != nil && AgentTabStore.registryHost(of: machine.daemon) != nil
        }
        while !ready(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        try #require(ready(), "the daemons did not come up")
        let connection = try #require(services.daemon.connection)
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        // A chat of this Mac with a session (agent-session-tabs-v1), as a chat the app opened.
        let record = AgentSessionRef(host: AgentSessionRef.host(installID: "cn-move-test"), hostName: "This Mac", session: "chat-live", harness: "claude")
        let created = try await connection.request(NewConversationTabRequest(agentSession: record, pane: pane.handle))
        let tabID = created.tabResourceID?.rawValue ?? "surface:\(created.surface.rawValue)"
        while services.locateTab(tabID) == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        try #require(services.locateTab(tabID) != nil, "the chat tab did not appear")

        let bridge = RegistryControlBridge(registry: services.registry)
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: bridge, settings: nil, configuration: .loadTolerant)
        router.updateCatalog(RegistryControlBridge.catalog(from: services.registry))
        let params: [String: JSONValue] = ["action": .string("cloud move"), "cli": .bool(true), "origin": .string("cli"), "wait": .bool(true),
                                           "target": .string("tab:" + tabID), "args": .object(["path": .string(project.path)])]
        if case .failure(let error) = await router.handle(ControlRequest(id: "1", method: "action.run", params: params)) {
            Issue.record("cmux cloud move: \(error.code) \(error.message)")
        }

        var moved = Moved()
        moved.surface = created.surface.rawValue
        moved.macSocket = await connection.endpoint?.socketPath ?? ""
        moved.machineStore = (AgentTabStore.registryHost(of: machine.daemon) ?? "").replacingOccurrences(of: "registry:", with: "")
        func machineChat() -> (TabModel, PaneModel)? {
            for workspace in machine.daemon.store.workspaces {
                for pane in workspace.screens.flatMap(\.panes) {
                    if let tab = pane.tabs.first(where: { $0.agentSession != nil }) { return (tab, pane) }
                }
            }
            return nil
        }
        while machineChat() == nil || services.locateTab(tabID) != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let (tab, pane) = machineChat() {
            moved.machineTab = tab
            let daemon = services.machines.daemon(forTab: tab)
            moved.attachesThroughMachine = (try? services.machines.agentDaemon(forTab: tab)) === machine.daemon
            moved.badge = services.machines.machineBadge(daemon.machineID)
            if let key = machine.daemon.store.workspace(containing: pane.handle)?.key,
               let listed = try await machine.daemon.connection?.listWorkspaces().workspaces.first(where: { $0.key == key }) {
                moved.terminalFolders = listed.screens.flatMap(\.panes).flatMap(\.tabs).filter { $0.kind == .pty }.compactMap(\.cwd)
            }
        }
        moved.macStillHasTab = services.locateTab(tabID) != nil
        let lines = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        moved.calls = lines.split(separator: "\n").map { $0.split(separator: "\u{1f}").map(String.init) }
        moved.folderName = moved.calls.first?.last.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return moved
    }

    /// A stand-in `cmux`: records each call's arguments (unit-separated) and answers
    /// `link sync push` and `link agent move` with their success lines.
    private static func standInCLI(in root: URL, log: URL) throws -> URL {
        let url = root.appendingPathComponent("cmux")
        let script = """
            #!/bin/sh
            line=""
            for arg in "$@"; do line="$line$(printf '\\037')$arg"; done
            printf '%s\\n' "${line#?}" >> '\(log.path)'
            case "$1 $2 $3" in
            "link sync push") echo '{"ok":true,"written":1,"unchanged":0,"deleted":0,"skipped":0,"bytes":4}' ;;
            "link agent move") echo '{"ok":true,"session_id":"chat-on-vm","transfer_id":"tr-1","bytes":42,"resolved":false}' ;;
            *) exit 64 ;;
            esac

            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A Cloud machine whose link this test replaces: its daemon is started on the second
    /// daemon's socket, so the link process never runs.
    private static func machine(_ services: AppServices, cli: URL, root: URL) -> CloudMachineSession {
        let paths = CloudPaths(root: root.appendingPathComponent("cloud", isDirectory: true))
        let api = services.cloud.api
        let hub = CloudTunnelHub(api: api, paths: paths, binary: cli, deviceName: "cn-move-test")
        let link = CloudMachineLink(machineID: "vm-move", api: api, hub: hub, paths: paths, binary: cli, deviceName: "cn-move-test")
        return CloudMachineSession(machine: CloudMachine(id: "vm-move", displayName: "Move VM"), link: link)
    }

    /// Ends `daemon`'s connection and its daemon with its terminals, so no host outlives the test.
    private static func end(_ daemon: DaemonService) async {
        guard let connection = daemon.connection else { return }
        daemon.shutdownConnection()
        await connection.close()
        _ = try? await connection.shutdownDaemon(endTerminals: true)
    }
}
