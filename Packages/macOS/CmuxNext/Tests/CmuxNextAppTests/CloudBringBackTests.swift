import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// Bring Back Local (cmuxterm-hq#1874 slice 4) at the app boundary: a chat moved to a Cloud machine
/// with `cmux cloud move` comes back with `cmux cloud bring-back`, both sent as the CLI sends them
/// to the app's real action registry. This Mac and the machine are two real cmux-tui daemons, as
/// in ``CloudMoveTests``; `cmux link sync push|pull` and `cmux link agent move` are a stand-in
/// `cmux` that records its arguments and answers as the case asks. The Rust suites cover those
/// CLIs against daemons (link_sync.rs, bring_back_journey.rs).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CloudBringBackTests {
    /// The chat comes back: the machine's folder is merged into the chat's folder here, the chat
    /// moves from the machine's tab to this Mac in that folder, and opens in a local tab bound to
    /// its session on this Mac; then the machine's tab closes.
    @Test func aCLIBringBackEndsWithTheChatInALocalTabAndTheMachineTabClosed() async throws {
        try await Self.withRoundTrip("back") { trip in
            if let error = await trip.bringBack() { Issue.record("cmux cloud bring-back: \(error.code) \(error.message)") }
            try await trip.waitUntil { trip.localChat() != nil && trip.machineChat() == nil }
            let calls = trip.calls()
            #expect(calls.count == 4, "\(calls)")
            #expect(calls.dropFirst(2).first == ["link", "sync", "pull", "--socket", trip.vmSocket, trip.project.path, trip.synced])
            #expect(calls.dropFirst(3).first == ["link", "agent", "move", "--from-socket", trip.vmSocket, "--surface", String(trip.machineSurface),
                                                 "--to-socket", trip.macSocket, "--cwd", trip.project.path])
            let local = try #require(trip.localChat(), "no chat tab on this Mac")
            #expect(local.agentSession?.session == "chat-live")
            #expect(local.agentSession?.host == trip.services.agentTabs.localHost)
            #expect(trip.machineChat() == nil, "the machine's tab is still open")
            #expect(trip.services.cloud.bringBackRetries[trip.machineKey] == nil)
        }
    }

    /// A conflict stops before the chat moves: the machine's tab stays, the conflicting path is
    /// in the message, and Retry runs the bring back again on the same machine.
    @Test func aSyncConflictKeepsTheMachineTabAndShowsTheConflict() async throws {
        try await Self.withRoundTrip("conflict") { trip in
            let error = try #require(await trip.bringBack(), "the bring back did not report the conflict")
            #expect(error.message.contains("notes.txt"), "the conflict is not shown: \(error.message)")
            #expect(trip.calls().count == 3, "the chat moved after a conflict: \(trip.calls())")
            #expect(trip.machineChat() != nil, "the machine's tab closed though the chat did not move")
            #expect(trip.localChat() == nil)
            #expect(trip.services.cloud.bringBackRetries[trip.machineKey] == .move(machineID: "vm-move"))
        }
    }

    /// The Mac's guard refuses a chat that approves everything: the machine's tab stays, the
    /// message names the setting in plain words, and Retry is offered for after it is changed.
    @Test func aGuardRefusalKeepsTheMachineTabWithAClearMessage() async throws {
        try await Self.withRoundTrip("policy") { trip in
            let error = try #require(await trip.bringBack(), "the bring back did not report the refusal")
            #expect(error.message == CloudBringBackStrings.policyBlocks, "\(error.message)")
            #expect(trip.calls().count == 4, "\(trip.calls())")
            #expect(trip.machineChat() != nil, "the machine's tab closed though the chat did not move")
            #expect(trip.localChat() == nil)
            #expect(trip.services.cloud.bringBackRetries[trip.machineKey] == .move(machineID: "vm-move"))
        }
    }

    /// The move back committed but the chat's tab here didn't open: the machine tab keeps its
    /// Bring Back Local row, also after a relaunch (which forgets in-memory retries), and running
    /// it again only opens the tab, without pulling or moving again.
    @Test func aCommittedBringBackWhoseTabFailedStillOpensItAfterARelaunch() async throws {
        try await Self.withRoundTrip("back") { trip in
            let host = trip.services.agentTabs.localHost
            trip.services.agentTabs.localHost = nil
            #expect(await trip.bringBack() != nil, "the bring back did not report the tab that failed")
            #expect(trip.calls().count == 4, "\(trip.calls())")
            trip.services.cloud.bringBackRetries[trip.machineKey] = nil
            trip.services.agentTabs.localHost = host
            let record = try #require(trip.machineChat()?.agentSession)
            #expect(!CloudBringBack.hiddenMenuItems(record, movedChats: trip.services.cloud.movedChats).contains(CloudBringBack.action),
                    "the machine tab lost its Bring Back Local row")
            if let error = await trip.bringBack() { Issue.record("cmux cloud bring-back again: \(error.code) \(error.message)") }
            try await trip.waitUntil { trip.localChat() != nil && trip.machineChat() == nil }
            #expect(trip.calls().count == 4, "it pulled or moved again: \(trip.calls())")
            #expect(trip.localChat()?.agentSession?.session == "chat-live")
            #expect(trip.machineChat() == nil, "the machine's tab is still open")
        }
    }

    /// A sync pull that throws (the CLI timed out) keeps the machine's tab and the bring back
    /// retryable on the same machine (cx-rppd.8).
    @Test func aSyncPullThatThrowsKeepsTheBringBackRetryable() async throws {
        try await Self.withRoundTrip("pullTimeout") { trip in
            #expect(await trip.bringBack() != nil, "the bring back did not report that it stopped")
            #expect(trip.calls().count == 3, "\(trip.calls())")
            #expect(trip.machineChat() != nil)
            #expect(trip.services.cloud.bringBackRetries[trip.machineKey] == .move(machineID: "vm-move"))
        }
    }

    // MARK: The harness

    /// One round trip's world: a chat moved from this Mac to a Cloud machine, and the stand-in CLI.
    @MainActor
    final class Trip {
        let services: AppServices
        let machine: CloudMachineSession
        let project: URL
        let log: URL
        let vmSocket: String
        var macSocket = ""
        /// The synced folder on the machine (`cmux link sync push`'s target).
        var synced = ""
        /// The moved chat's tab on the machine, as the app keys it, and its surface there.
        var machineKey = ""
        var machineSurface: UInt64 = 0

        init(services: AppServices, machine: CloudMachineSession, project: URL, log: URL, vmSocket: String) {
            self.services = services
            self.machine = machine
            self.project = project
            self.log = log
            self.vmSocket = vmSocket
        }

        /// The machine's chat tab, if it has one.
        func machineChat() -> TabModel? { Self.chat(in: machine.daemon.store) }

        /// This Mac's chat tab, if it has one.
        func localChat() -> TabModel? { Self.chat(in: services.daemon.store) }

        /// A tab bound to a chat's session; a new chat's empty tab (no session yet) is not one.
        private static func chat(in store: DaemonStore) -> TabModel? {
            store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.agentSession?.session != nil }
        }

        func calls() -> [[String]] {
            let lines = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return lines.split(separator: "\n").map { $0.split(separator: "\u{1f}").map(String.init) }
        }

        /// `cmux <action>` on tab `tab`, as the CLI sends it; its error when it stopped.
        func run(_ action: String, tab: String, args: [String: CmuxNextSettings.JSONValue] = [:]) async -> ControlError? {
            let bridge = RegistryControlBridge(registry: services.registry)
            let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                                 processID: getpid()),
                                       executor: bridge, settings: nil,
                                       configuration: ControlRouter.Configuration(requestDeadline: .seconds(60)))
            router.updateCatalog(RegistryControlBridge.catalog(from: services.registry))
            let params: [String: CmuxNextSettings.JSONValue] = ["action": .string(action), "cli": .bool(true), "origin": .string("cli"),
                                                                "wait": .bool(true), "target": .string("tab:" + tab), "args": .object(args)]
            if case .failure(let error) = await router.handle(ControlRequest(id: "1", method: "action.run", params: params)) { return error }
            return nil
        }

        /// `cmux cloud bring-back` on the machine's chat tab.
        func bringBack() async -> ControlError? { await run("cloud bring-back", tab: machineKey) }

        /// Polls `condition` for up to a minute.
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(60)
            while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }
    }

    /// Runs `body` once a live chat of this Mac moved to a connected Cloud machine; the stand-in CLI
    /// answers the bring back as `mode` says (`back`, `conflict`, `policy`, `pullTimeout`).
    private static func withRoundTrip(_ mode: String, _ body: (Trip) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = URL(fileURLWithPath: "/private/tmp/cn-back-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
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
        let mac = DaemonLauncher(configuration: .init(binary: binary, session: "cn-back-mac-\(UUID().uuidString.prefix(6).lowercased())",
                                                      stateDirectory: root.appendingPathComponent("mac-state")), environment: environment)
        let vm = DaemonLauncher(configuration: .init(binary: binary, session: "cn-back-vm-\(UUID().uuidString.prefix(6).lowercased())",
                                                     stateDirectory: root.appendingPathComponent("vm-state")), environment: environment)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.cloud.move = CloudMoveSetup(cli: cli, workRoots: [workRoot.path], timeout: .seconds(5))
        services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-back-test")
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: mac.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        let vmSocket = try await vm.endpointProvider().socketPath
        let machine = CloudMoveTests.machine(services, cli: cli, root: root)
        services.machines.add(machine)
        machine.daemon.start(remote: { vmSocket })

        let trip = Trip(services: services, machine: machine, project: project, log: log, vmSocket: vmSocket)
        let result: Result<Void, any Error>
        do {
            try await moveToCloud(trip)
            try await body(trip)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await CloudMoveTests.end(services.daemon)
        await CloudMoveTests.end(machine.daemon)
        for controller in services.windows.controllers { controller.window?.close() }
        try result.get()
    }

    /// Opens a live chat in this Mac's first workspace and moves it to the machine with
    /// `cmux cloud move`, as a person would before bringing it back.
    private static func moveToCloud(_ trip: Trip) async throws {
        let services = trip.services, machine = trip.machine
        let deadline = ContinuousClock.now + .seconds(60)
        func ready() -> Bool {
            services.daemon.store.workspaces.contains { $0.screens.contains { !$0.panes.isEmpty } }
                && machine.daemon.connection != nil && AgentTabStore.registryHost(of: machine.daemon) != nil
        }
        while !ready(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        try #require(ready(), "the daemons did not come up")
        trip.macSocket = await services.daemon.connection?.endpoint?.socketPath ?? ""
        let connection = try #require(services.daemon.connection)
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let record = AgentSessionRef(host: try #require(services.agentTabs.localHost), hostName: "This Mac", session: "chat-live", harness: "claude")
        let created = try await connection.request(NewConversationTabRequest(agentSession: record, pane: pane.handle))
        let tabID = created.tabResourceID?.rawValue ?? "surface:\(created.surface.rawValue)"
        while services.locateTab(tabID) == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if let error = await trip.run("cloud move", tab: tabID, args: ["path": .string(trip.project.path)]) {
            Issue.record("cmux cloud move: \(error.code) \(error.message)")
        }
        try await trip.waitUntil { trip.machineChat() != nil && trip.localChat() == nil }
        let moved = try #require(trip.machineChat(), "the chat did not move to the machine")
        trip.machineKey = moved.id
        trip.machineSurface = moved.surface.rawValue
        trip.synced = try #require(trip.calls().first?.last)
    }

    /// A stand-in `cmux` (calls recorded unit-separated): `link sync push` makes the synced folder
    /// and `link agent move` moves the chat to the machine, leaving the landed chat's record as the
    /// machine daemon's `agent-transfer-finish` would (see ``CloudMoveTests``); then `link sync
    /// pull` and the move back answer as `mode` says.
    private static func standInCLI(in root: URL, log: URL, mode: String, vmState: URL) throws -> URL {
        let url = root.appendingPathComponent("cmux")
        let pulled = root.appendingPathComponent("pulled").path
        let script = """
            #!/bin/sh
            line=""
            for arg in "$@"; do line="$line$(printf '\\037')$arg"; done
            printf '%s\\n' "${line#?}" >> '\(log.path)'
            case "$1 $2 $3" in
            "link sync push")
                for target in "$@"; do :; done
                mkdir -p "$target"
                echo '{"ok":true,"written":1,"unchanged":0,"deleted":0,"skipped":0,"bytes":4}' ;;
            "link sync pull")
                case '\(mode)' in
                conflict) echo '{"ok":false,"error":"notes.txt changed both here and on the machine","error_code":"sync_conflict","conflicts":["notes.txt"]}'; exit 1 ;;
                pullTimeout) exec sleep 30 ;;
                *) touch '\(pulled)'; echo '{"ok":true,"written":1,"unchanged":0,"deleted":0,"skipped":0,"bytes":4,"fast_forwarded":true,"head":null}' ;;
                esac ;;
            "link agent move")
                if [ ! -f '\(pulled)' ]; then
                    registry=$(find '\(vmState.path)' -name workspace-registry.sqlite3 -print | head -n 1)
                    [ -n "$registry" ] || exit 70
                    printf '[{"session":"chat-on-vm","landed_at_ms":%s000}]' "$(date +%s)" > "$(dirname "$registry")/agent-transfer-landed.json"
                    echo '{"ok":true,"session_id":"chat-on-vm","transfer_id":"tr-1","bytes":42,"resolved":false}'
                elif [ '\(mode)' = policy ]; then
                    echo '{"ok":false,"error":"the machine did not take the chat: acpmux refused the request: transfer.policy: approve-all","error_code":"agent_transfer.refused"}'
                    exit 1
                else
                    echo '{"ok":true,"session_id":"chat-live","transfer_id":"tr-back","bytes":42,"resolved":false}'
                fi ;;
            *) exit 64 ;;
            esac

            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
