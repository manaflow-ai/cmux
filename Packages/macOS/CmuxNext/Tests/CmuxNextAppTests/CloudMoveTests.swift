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
/// JSON lines as the case asks; the Rust suites cover those CLIs against daemons (link_sync.rs,
/// link_agent_move.rs, cloud_move_journey.rs).
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CloudMoveTests {
    /// The live chat moves: its folder is synced under the machine's work root, the chat is moved
    /// from this Mac's tab to that folder, and the machine shows it in a Cloud workspace whose
    /// terminal runs in the synced folder. The chat's tab there is bound to the moved session
    /// through the machine's store (so it attaches through that machine and carries its badge),
    /// and this Mac's tab, whose chat closed, is gone.
    @Test func aCLIMoveOfALiveChatEndsWithTheTabAttachedToTheMachineChat() async throws {
        try await Self.withMove("moves") { move in
            if let error = await move.run() { Issue.record("cmux cloud move: \(error.code) \(error.message)") }
            let moved = try await move.read()

            let synced = move.workRoot.appendingPathComponent(moved.folderName).path
            #expect(moved.calls.first == ["link", "sync", "push", "--socket", move.vmSocket, move.project.path, synced])
            #expect(moved.calls.dropFirst().first == ["link", "agent", "move", "--from-socket", moved.macSocket, "--surface", String(moved.surface),
                                                     "--to-socket", move.vmSocket, "--cwd", synced])
            #expect(moved.calls.count == 2)
            // The machine shows the chat: bound to the moved session through that machine's store.
            let tab = try #require(moved.machineTab, "no chat tab on the machine")
            #expect(tab.agentSession?.session == "chat-on-vm")
            #expect(tab.agentSession?.host == "registry:" + moved.machineStore)
            #expect(tab.agentSession?.harness == "claude")
            #expect(moved.attachesThroughMachine, "the moved chat does not attach through the machine")
            #expect(moved.badge == "Move VM", "the moved chat's tab carries no Cloud badge")
            #expect(moved.terminalFolders == [synced], "the machine workspace's terminal is not in the synced folder")
            // This Mac's tab is gone (its chat closed with the move), with nothing left to retry.
            #expect(!moved.macStillHasTab)
            #expect(move.services.cloud.moveRetries[move.key] == nil)
        }
    }

    /// How a move stops: the stand-in `cmux link agent move` answer (or the machine tab's failure).
    enum Stop: String, CaseIterable, Sendable {
        case unresolved, inProgress, badAnswer, timeout, tabFailed, teamMachine
    }

    /// A move that stops keeps this Mac's tab and leaves the right Retry: one that may not have
    /// moved the chat runs the move again on the same machine; one whose chat moved but whose
    /// machine tab didn't open only opens that tab, without syncing or moving again; a team
    /// machine offers none.
    @Test(arguments: Stop.allCases)
    func aMoveThatStopsKeepsTheTabAndRetriesOnlyWhatIsLeft(_ stop: Stop) async throws {
        try await Self.withMove(stop.rawValue) { move in
            let error = await move.run()
            #expect(error != nil, "the move did not report that it stopped")
            #expect(move.services.locateTab(move.tabID) != nil, "this Mac's tab closed though its chat is not on the machine")
            let calls = move.calls()
            #expect(calls.count == 2, "\(calls)")
            let retry = move.services.cloud.moveRetries[move.key]
            switch stop {
            case .teamMachine:
                #expect(retry == nil, "a team machine is offered Retry")
            case .unresolved, .inProgress, .badAnswer, .timeout:
                #expect(retry == .move(machineID: "vm-move"), "Retry does not finish the move on its machine: \(String(describing: retry))")
            case .tabFailed:
                guard case .show(let shown) = retry else {
                    Issue.record("Retry does not only open the moved chat's tab: \(String(describing: retry))")
                    return
                }
                let synced = try #require(calls.first?.last)
                #expect(shown.session == "chat-on-vm" && shown.machineID == "vm-move" && shown.folder == synced && shown.key == "tr-1")
                // Retry, once the folder is there: only the tab opens.
                try FileManager.default.createDirectory(atPath: synced, withIntermediateDirectories: true)
                if let again = await move.run() { Issue.record("Retry failed: \(again.code) \(again.message)") }
                let moved = try await move.read()
                #expect(moved.calls.count == 2, "Retry synced or moved the chat again: \(moved.calls)")
                #expect(moved.machineTab?.agentSession?.session == "chat-on-vm", "Retry did not open the moved chat's tab")
                #expect(moved.terminalFolders == [synced])
                #expect(!moved.macStillHasTab)
                #expect(move.services.cloud.moveRetries[move.key] == nil)
            }
        }
    }

    /// A sync that throws instead of answering (the CLI timed out, or didn't launch) keeps this
    /// Mac's tab and the move retryable on the same machine; it never clears that Retry (cx-rppd.8).
    @Test func aSyncThatThrowsKeepsTheMoveRetryableOnItsMachine() async throws {
        try await Self.withMove("syncTimeout") { move in
            let error = await move.run()
            #expect(error != nil, "the move did not report that it stopped")
            #expect(move.services.locateTab(move.tabID) != nil, "this Mac's tab closed though nothing moved")
            #expect(move.calls().count == 1, "the chat moved after a failed sync: \(move.calls())")
            let retry = move.services.cloud.moveRetries[move.key]
            #expect(retry == .move(machineID: "vm-move"), "Retry does not run the move again on its machine: \(String(describing: retry))")
        }
    }

    // MARK: The harness

    /// One move's world: this Mac's daemon with a live chat tab, a Cloud machine on a second
    /// daemon, and the stand-in CLI.
    @MainActor
    final class Move {
        let services: AppServices
        let machine: CloudMachineSession
        let project: URL
        let workRoot: URL
        let log: URL
        let vmSocket: String
        var tabID = ""
        /// The chat tab's id on this Mac, as the app keys it.
        var key = ""
        /// The chat tab's surface on this Mac.
        var surface: UInt64 = 0

        init(services: AppServices, machine: CloudMachineSession, project: URL, workRoot: URL, log: URL, vmSocket: String) {
            self.services = services
            self.machine = machine
            self.project = project
            self.workRoot = workRoot
            self.log = log
            self.vmSocket = vmSocket
        }

        /// `cmux cloud move` on the chat tab; its error when it stopped.
        func run() async -> ControlError? {
            let bridge = RegistryControlBridge(registry: services.registry)
            let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                                 processID: getpid()),
                                       executor: bridge, settings: nil,
                                       configuration: ControlRouter.Configuration(requestDeadline: .seconds(60)))
            router.updateCatalog(RegistryControlBridge.catalog(from: services.registry))
            let params: [String: CmuxNextSettings.JSONValue] = ["action": .string("cloud move"), "cli": .bool(true), "origin": .string("cli"),
                                                                "wait": .bool(true), "target": .string("tab:" + tabID),
                                                                "args": .object(["path": .string(project.path)])]
            if case .failure(let error) = await router.handle(ControlRequest(id: "1", method: "action.run", params: params)) { return error }
            return nil
        }

        /// The stand-in CLI's calls so far, each as its arguments.
        func calls() -> [[String]] {
            let lines = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return lines.split(separator: "\n").map { $0.split(separator: "\u{1f}").map(String.init) }
        }

        /// Both trees once the machine shows a chat and this Mac's tab is gone (or a minute passed).
        func read() async throws -> Moved {
            let deadline = ContinuousClock.now + .seconds(60)
            var moved = Moved()
            moved.surface = surface
            moved.macSocket = await services.daemon.connection?.endpoint?.socketPath ?? ""
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
            moved.calls = calls()
            moved.folderName = moved.calls.first?.last.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            return moved
        }
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

    /// Runs `body` with a live chat tab on this Mac and a connected Cloud machine; the stand-in
    /// CLI answers as `mode` says (``Stop``'s raw values, or `moves`).
    private static func withMove(_ mode: String, _ body: (Move) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        // A real path (no /tmp symlink): the daemon reports a terminal's folder as it launched it.
        let root = URL(fileURLWithPath: "/private/tmp/cn-move-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let workRoot = root.appendingPathComponent("vm-home/work", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("cli.log")
        let cli = try standInCLI(in: root, log: log, mode: mode, vmState: root.appendingPathComponent("vm-state"))

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
        services.cloud.move = CloudMoveSetup(cli: cli, workRoots: [workRoot.path], timeout: .seconds(5))
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: mac.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        let vmSocket = try await vm.endpointProvider().socketPath
        let machine = Self.machine(services, cli: cli, root: root)
        services.machines.add(machine)
        machine.daemon.start(remote: { vmSocket })

        let move = Move(services: services, machine: machine, project: project, workRoot: workRoot, log: log, vmSocket: vmSocket)
        let result: Result<Void, any Error>
        do {
            try await openChat(move)
            try await body(move)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await end(services.daemon)
        await end(machine.daemon)
        for controller in services.windows.controllers { controller.window?.close() }
        try result.get()
    }

    /// Opens a live chat (with a session) in this Mac's first workspace, as a chat the app opened.
    private static func openChat(_ move: Move) async throws {
        let services = move.services, machine = move.machine
        let deadline = ContinuousClock.now + .seconds(60)
        func ready() -> Bool {
            services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } }
                && machine.daemon.connection != nil && AgentTabStore.registryHost(of: machine.daemon) != nil
        }
        while !ready(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        try #require(ready(), "the daemons did not come up")
        let connection = try #require(services.daemon.connection)
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let record = AgentSessionRef(host: AgentSessionRef.host(installID: "cn-move-test"), hostName: "This Mac", session: "chat-live", harness: "claude")
        let created = try await connection.request(NewConversationTabRequest(agentSession: record, pane: pane.handle))
        move.tabID = created.tabResourceID?.rawValue ?? "surface:\(created.surface.rawValue)"
        move.surface = created.surface.rawValue
        while services.locateTab(move.tabID) == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        move.key = try #require(services.locateTab(move.tabID)?.0.id, "the chat tab did not appear")
    }

    /// A stand-in `cmux`: records each call's arguments (unit-separated). Like the real sync,
    /// `link sync push` creates the synced folder (not in `tabFailed`, so the machine's terminal
    /// can't start there; in `syncTimeout` it outlives the CLI timeout); `link agent move`
    /// answers as `mode` says. A move that answers ok also leaves what the machine daemon's own
    /// `agent-transfer-finish` would: the landed chat's record (`agent-transfer-landed.json` next
    /// to that daemon's registry in `vmState`), without which the daemon refuses a `registry:` tab
    /// naming the chat (cx-k21v).
    private static func standInCLI(in root: URL, log: URL, mode: String, vmState: URL) throws -> URL {
        let url = root.appendingPathComponent("cmux")
        let script = """
            #!/bin/sh
            line=""
            for arg in "$@"; do line="$line$(printf '\\037')$arg"; done
            printf '%s\\n' "${line#?}" >> '\(log.path)'
            case "$1 $2 $3" in
            "link sync push")
                [ '\(mode)' = syncTimeout ] && exec sleep 30
                for target in "$@"; do :; done
                [ '\(mode)' = tabFailed ] || mkdir -p "$target"
                echo '{"ok":true,"written":1,"unchanged":0,"deleted":0,"skipped":0,"bytes":4}' ;;
            "link agent move")
                case '\(mode)' in
                unresolved) echo '{"ok":false,"error":"the move did not finish","error_code":"move_unresolved","retry_after_seconds":5}'; exit 1 ;;
                inProgress) echo '{"ok":false,"error":"the chat is moving","error_code":"move_in_progress"}'; exit 1 ;;
                badAnswer) echo 'thread main panicked'; exit 101 ;;
                timeout) exec sleep 30 ;;
                teamMachine) echo '{"ok":false,"error":"a team machine","error_code":"agent_session.team_vm_blocked"}'; exit 1 ;;
                *)
                    registry=$(find '\(vmState.path)' -name workspace-registry.sqlite3 -print | head -n 1)
                    [ -n "$registry" ] || exit 70
                    printf '[{"session":"chat-on-vm","landed_at_ms":%s000}]' "$(date +%s)" > "$(dirname "$registry")/agent-transfer-landed.json"
                    echo '{"ok":true,"session_id":"chat-on-vm","transfer_id":"tr-1","bytes":42,"resolved":false}' ;;
                esac ;;
            *) exit 64 ;;
            esac

            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// A Cloud machine whose link this test replaces: its daemon is started on the second
    /// daemon's socket, so the link process never runs.
    static func machine(_ services: AppServices, cli: URL, root: URL) -> CloudMachineSession {
        let paths = CloudPaths(root: root.appendingPathComponent("cloud", isDirectory: true))
        let api = services.cloud.api
        let hub = CloudTunnelHub(api: api, paths: paths, binary: cli, deviceName: "cn-move-test")
        let link = CloudMachineLink(machineID: "vm-move", api: api, hub: hub, paths: paths, binary: cli, deviceName: "cn-move-test")
        return CloudMachineSession(machine: CloudMachine(id: "vm-move", displayName: "Move VM"), link: link)
    }

    /// Ends `daemon`'s connection and its daemon with its terminals, so no host outlives the test.
    static func end(_ daemon: DaemonService) async {
        guard let connection = daemon.connection else { return }
        daemon.shutdownConnection()
        await connection.close()
        _ = try? await connection.shutdownDaemon(endTerminals: true)
    }
}
