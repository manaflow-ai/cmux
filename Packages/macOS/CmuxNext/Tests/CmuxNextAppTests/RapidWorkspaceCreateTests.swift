import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Cmd-N at key-repeat speed with Close Workspace pressed in between, on the real daemon and the
/// app's launch window (cx-7cit9, Leo: "rapid Cmd-N outraces creation, workspaces 3-6 missing
/// from the sidebar, and deleting during that shows a raw `no workspace <id>` toast").
/// - every workspace asked for and not closed is in the window's sidebar, in press order;
/// - each close takes exactly one workspace, and a closed one never comes back;
/// - no press fails, and no notice names a raw id.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct RapidWorkspaceCreateTests {
    private static let presses = 20
    /// Close Workspace is pressed right after these presses.
    private static let closesAfter: Set<Int> = [5, 6, 12, 18]

    @MainActor private final class Notices {
        var shown: [String] = []
    }

    private static func name(_ press: Int) -> String { String(format: "race-%02d", press) }

    /// Polls until `done` holds or `limit` passes (a poll, as in `FirstLaunchTests`).
    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func twentyCmdNWithClosesInBetweenKeepEveryWorkspaceInPressOrder() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-race-\(UUID().uuidString.prefix(8))")
        let session = "cn-race-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        let store = services.daemon.store
        defer { try? FileManager.default.removeItem(at: root) }
        defer {
            services.daemon.shutdownConnection()
            for controller in services.windows.controllers { controller.window?.close() }
        }

        // The launch window shows its first workspace.
        await Self.wait(within: .seconds(90)) {
            services.windows.active.flatMap { services.windows.registry.members(of: $0.state.id).first } != nil
        }
        let window = try #require(services.windows.active?.state.id)
        let before = Set(store.workspaces.map(\.id))
        // The notices a keyboard run shows (a quiet refusal shows none).
        let notices = Notices()
        let shows = services.registry.refusalObserver
        services.registry.refusalObserver = { reason, quiet in
            if !quiet { notices.shown.append(reason) }
            shows?(reason, quiet)
        }

        // 20 presses inside a second (key repeat), each named so its sidebar row says which press
        // made it, with Close Workspace pressed between some of them.
        var work: [ActionWork] = []
        let started = ContinuousClock.now
        for press in 1...Self.presses {
            work += services.registry.capturingWork {
                _ = services.registry.perform("newTab", invocation: ActionInvocation(arguments: ["name": .string(Self.name(press))]))
            }
            if Self.closesAfter.contains(press) {
                work += services.registry.capturingWork { _ = services.registry.perform("closeWorkspace") }
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        let pressing = ContinuousClock.now - started
        var failures: [String] = []
        for task in work { if let failure = await task.value { failures.append(failure.message) } }

        // Settled: nothing in flight, and the store and the window agree.
        let expected = before.count + Self.presses - Self.closesAfter.count
        await Self.wait(within: .seconds(30)) {
            store.workspaces.count == expected && Set(services.windows.registry.members(of: window)) == Set(store.workspaces.map(\.id))
        }
        // A closed workspace that would come back (a create that finished after its close) shows
        // within this; test-only wait.
        try? await Task.sleep(for: .seconds(2))

        let members = Set(services.windows.registry.members(of: window))
        let created = store.workspaces.filter { !before.contains($0.id) }
        let order = WindowManager.orderedIDs(of: services.daemon, machines: services.machines).filter(members.contains)
        let presses = order.compactMap { id in created.first { $0.id == id }?.name }.compactMap { name in
            (1...Self.presses).first { Self.name($0) == name }
        }
        let ids = before.union(created.map(\.id))
        let refusals = notices.shown

        if let connection = services.daemon.connection, let identity = services.daemon.identity {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }

        #expect(pressing < .seconds(1))
        // Each close took exactly one workspace; none of the others is missing.
        #expect(store.workspaces.count == expected)
        #expect(created.allSatisfy { members.contains($0.id) }, "not in the sidebar: \(created.filter { !members.contains($0.id) }.map(\.name))")
        #expect(presses.count == created.count, "unnamed or duplicate workspaces: \(created.map(\.name))")
        // Press order: each new workspace lands at the same end (top or bottom, by the setting).
        #expect(presses == presses.sorted() || presses == presses.sorted(by: >), "sidebar order by press: \(presses)")
        #expect(failures.isEmpty, "failed: \(failures)")
        #expect(refusals.isEmpty, "notices: \(refusals)")
        #expect(!(failures + refusals).contains { message in ids.contains { message.contains($0) } })
    }
}
