import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// `cmux agent open S --host <machine>` in a build without the agent page is refused the way the
/// same open on this Mac is, before anything is made. It made a workspace on that machine and bound
/// the session into an agent tab that could not show it. The other machine is a real cmux-tui
/// daemon reached as the app reaches a machine's link socket, as in ``CrossMachineTabMoveTests``.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AgentSessionAdoptNoPageTests {
    /// Every workspace id the other machine's store listed while the open ran.
    @MainActor final class Seen {
        var ids: Set<String> = []
        /// When the watch stops: set once the open's work has finished.
        var until: ContinuousClock.Instant?
    }

    @Test func anotherMachinesChatIsRefusedWithoutTheAgentPageAndMakesNoWorkspace() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = URL(fileURLWithPath: "/private/tmp/cn-adopt-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment: @Sendable () -> [String: String] = {
            ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"]
        }
        let vm = DaemonLauncher(configuration: .init(binary: binary, session: "cn-adopt-vm-\(UUID().uuidString.prefix(6).lowercased())",
                                                     stateDirectory: root.appendingPathComponent("vm-state")), environment: environment)
        _ = NSApplication.shared
        let vmSocket = try await vm.endpointProvider().socketPath
        // A build without the agent page (and no dev server): no chat can show here. The mock host starts no acpmux.
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneEnvironment: ["CMUX_NEXT_AGENT_PANE_NONE": "1", "CMUX_NEXT_AGENT_PANE_MOCK": "1"])
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let machine = CloudMoveTests.machine(services, cli: URL(fileURLWithPath: "/usr/bin/false"), root: root)
        services.machines.add(machine)
        machine.daemon.start(remote: { vmSocket })

        let result: Result<Void, any Error>
        do {
            try #require(!services.agentTabs.canHostChat, "this test build has the agent page")
            let deadline = ContinuousClock.now + .seconds(60)
            while machine.daemon.connection == nil || machine.daemon.identity == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try #require(machine.daemon.connection != nil, "the other machine did not connect")
            try #require(services.machines.remoteDaemon(named: machine.machineID) === machine.daemon, "the host names no machine")
            let before = Set(machine.daemon.store.workspaces.map(\.id))

            // Every workspace the other machine lists while the open runs, even one closed again.
            let seen = Seen()
            let store = machine.daemon.store
            let watch = Task { @MainActor in
                while seen.until.map({ ContinuousClock.now < $0 }) ?? true {
                    seen.ids.formUnion(store.workspaces.map(\.id))
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            var work: [ActionWork] = []
            let refusal = services.registry.capturingRefusal {
                work = services.registry.capturingWork {
                    _ = services.registry.perform("agent.openSessionWorkspace", invocation: ActionInvocation(arguments: [
                        "session": .string("lane-1"), "host": .string(machine.machineID), "key": .string(UUID().uuidString.lowercased()),
                    ]))
                }
            }
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            // The watch runs 500 ms more: a late tree event would land in that window.
            seen.until = ContinuousClock.now + .milliseconds(500)
            await watch.value
            seen.ids.formUnion(store.workspaces.map(\.id))

            #expect(refusal?.contains(MiscHandlerStrings.quickChatUnavailable) == true,
                    "the open was not refused for the missing agent page: \(String(describing: refusal)) \(failures)")
            #expect(work.isEmpty, "the refused open still started work: \(failures)")
            #expect(seen.ids.subtracting(before).isEmpty, "the other machine made a workspace: \(seen.ids.subtracting(before))")
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await CloudMoveTests.end(machine.daemon)
        for controller in services.windows.controllers { controller.window?.close() }
        try result.get()
    }

    /// With the agent page, an adopt the other machine refuses (no acpmux there lists the session)
    /// leaves nothing behind on it: the workspace the open made for the chat, its terminal and its
    /// unbound agent tab, closes again. Base's half-created close only closes an EMPTY workspace,
    /// and this one already held both tabs, so it stayed.
    @Test func aRefusedAdoptClosesTheWorkspaceItMade() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = URL(fileURLWithPath: "/private/tmp/cn-adopt-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment: @Sendable () -> [String: String] = {
            ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"]
        }
        let vm = DaemonLauncher(configuration: .init(binary: binary, session: "cn-adopt-vm-\(UUID().uuidString.prefix(6).lowercased())",
                                                     stateDirectory: root.appendingPathComponent("vm-state")), environment: environment)
        _ = NSApplication.shared
        let vmSocket = try await vm.endpointProvider().socketPath
        // The mock host starts no acpmux, so the other machine lists no session to adopt.
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneEnvironment: ["CMUX_NEXT_AGENT_PANE_MOCK": "1"])
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let machine = CloudMoveTests.machine(services, cli: URL(fileURLWithPath: "/usr/bin/false"), root: root)
        services.machines.add(machine)
        machine.daemon.start(remote: { vmSocket })

        let result: Result<Void, any Error>
        do {
            try #require(services.agentTabs.canHostChat, "this test build has no agent page")
            let connectDeadline = ContinuousClock.now + .seconds(60)
            while machine.daemon.connection == nil || machine.daemon.identity == nil, ContinuousClock.now < connectDeadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try #require(machine.daemon.connection != nil, "the other machine did not connect")
            try #require(services.machines.remoteDaemon(named: machine.machineID) === machine.daemon, "the host names no machine")
            let store = machine.daemon.store
            let before = Set(store.workspaces.map(\.id))
            let key = UUID().uuidString.lowercased()

            var work: [ActionWork] = []
            let refusal = services.registry.capturingRefusal {
                work = services.registry.capturingWork {
                    _ = services.registry.perform("agent.openSessionWorkspace", invocation: ActionInvocation(arguments: [
                        "session": .string("lane-missing"), "host": .string(machine.machineID), "key": .string(key),
                    ]))
                }
            }
            #expect(refusal == nil, "the open was refused before it reached the other machine: \(String(describing: refusal))")
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(!failures.isEmpty, "the other machine adopted a session no acpmux lists")

            // The close is a daemon commit; the store mirrors it once the tree event lands.
            let settleDeadline = ContinuousClock.now + .seconds(10)
            while Set(store.workspaces.map(\.id)) != before, ContinuousClock.now < settleDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let left = Set(store.workspaces.map(\.id)).subtracting(before)
            #expect(left.isEmpty, "the refused adopt left a workspace on the other machine: \(left) \(failures)")
            #expect(services.machines.workspace(id: key) == nil, "the refused adopt's workspace is still listed")
            // Its repair claim goes with it: a failed adopt never leaves the key settling.
            let repair = services.machines.emptyWorkspaceRepair(machine.daemon.machineID, local: services.emptyWorkspaces)
            #expect(!repair.isSettling(WorkspaceKey(rawValue: key)), "the refused adopt's workspace is still settling in the repair")
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await CloudMoveTests.end(machine.daemon)
        for controller in services.windows.controllers { controller.window?.close() }
        try result.get()
    }

    /// A failed adopt whose failure is the other machine's link dropping still closes the workspace
    /// it made there: the close waits for the link to come back, never runs on the dead connection.
    @Test func aFailedAdoptsWorkspaceClosesOnceTheMachineReconnects() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = URL(fileURLWithPath: "/private/tmp/cn-adopt-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment: @Sendable () -> [String: String] = {
            ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"]
        }
        let vm = DaemonLauncher(configuration: .init(binary: binary, session: "cn-adopt-vm-\(UUID().uuidString.prefix(6).lowercased())",
                                                     stateDirectory: root.appendingPathComponent("vm-state")), environment: environment)
        _ = NSApplication.shared
        let vmSocket = try await vm.endpointProvider().socketPath
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneEnvironment: ["CMUX_NEXT_AGENT_PANE_MOCK": "1"])
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let machine = CloudMoveTests.machine(services, cli: URL(fileURLWithPath: "/usr/bin/false"), root: root)
        services.machines.add(machine)
        let daemon = machine.daemon
        daemon.start(remote: { vmSocket })

        let result: Result<Void, any Error>
        do {
            let connectDeadline = ContinuousClock.now + .seconds(60)
            while !daemon.isLive || daemon.identity == nil, ContinuousClock.now < connectDeadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let connection = try #require(daemon.connection, "the other machine did not connect")
            // The workspace an adopt made there: a terminal, as the adopt's first step leaves it.
            let key = WorkspaceKey.generate()
            _ = try await connection.createWorkspaceRetryingLateReplies(name: "adopt", key: key)
            try await connection.createTerminal(in: key, cwd: nil)

            // The link drops (the adopt's failure), then comes back while the close is under way.
            daemon.shutdownConnection()
            #expect(!daemon.isLive)
            let closing = Task { @MainActor in
                try await AgentSessionWorkspace.closeFailedAdopt(key, on: daemon, present: { true })
            }
            daemon.start(remote: { vmSocket })
            let closeResult = await closing.result
            #expect((try? closeResult.get()) != nil, "the close failed: \(closeResult)")

            let reconnectDeadline = ContinuousClock.now + .seconds(60)
            while !daemon.isLive, ContinuousClock.now < reconnectDeadline { try? await Task.sleep(for: .milliseconds(100)) }
            let live = try #require(daemon.connection, "the other machine did not reconnect")
            await daemon.store.applied(through: await live.eventSequence())
            #expect(!daemon.store.workspaces.contains { $0.key == key }, "the failed adopt's workspace stayed on the other machine")
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await CloudMoveTests.end(daemon)
        for controller in services.windows.controllers { controller.window?.close() }
        try result.get()
    }
}
