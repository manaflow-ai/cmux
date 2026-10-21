import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
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
        // No dev server and no bundled page (the package tests build none): no chat can show here.
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneEnvironment: [:])
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
                while !Task.isCancelled {
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
            try? await Task.sleep(for: .milliseconds(500)) // test-only: a late tree event would land here
            watch.cancel()
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
}
