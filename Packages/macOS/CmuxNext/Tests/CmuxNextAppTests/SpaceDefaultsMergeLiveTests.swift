import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Set Space Terminal Defaults… on the real daemon: a run that names only `cwd` keeps the space's
/// environment, and one that names only `env` keeps its directory, from the palette and from the CLI
/// alike. It used to replace both, so `cmux space set-defaults --cwd X` (or the palette's directory
/// answer, had it not copied the env in) dropped the space's environment. Clear Space Terminal
/// Defaults…, confirmed, removes both.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct SpaceDefaultsMergeLiveTests {
    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func oneArgumentKeepsTheOtherAndClearDefaultsRemovesBoth() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-sdef-\(UUID().uuidString.prefix(8))")
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-sdef-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let result: Result<Void, any Error>
        do {
            try await Self.exercise(services)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        if let connection = services.daemon.connection, let identity = services.daemon.identity {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }
        services.daemon.shutdownConnection()
        for controller in services.windows.controllers { controller.window?.close() }
        try result.get()
    }

    private static func exercise(_ services: AppServices) async throws {
        let store = services.machines.local.store
        await wait(within: .seconds(90)) { services.daemon.connection != nil && store.personal.isLoaded }
        let connection = try #require(services.daemon.connection, "the daemon did not come up")
        let made = try await connection.createProfile(name: "Work", defaults: ProfileDefaults(cwd: "/tmp/work", env: ["A": "1"]))
        let id = made.id, target = ActionTargetRef(kind: .profile, id: made.id.rawValue)
        func defaults() -> ProfileDefaults? { store.profile(id)?.defaults }
        await wait(within: .seconds(30)) { defaults()?.cwd == "/tmp/work" }
        try #require(defaults() == ProfileDefaults(cwd: "/tmp/work", env: ["A": "1"]), "the space never showed its defaults")

        // The palette's answer to its directory question: `cwd` alone, from a person.
        let pick = ActionInvocation(target: target, arguments: ["cwd": .string("/tmp/other")], origin: .user)
        #expect(services.registry.perform("space.setDefaults", invocation: pick))
        await wait(within: .seconds(30)) { defaults()?.cwd == "/tmp/other" }
        #expect(defaults()?.cwd == "/tmp/other")
        #expect(defaults()?.env == ["A": "1"], "--cwd alone dropped the space's environment: \(String(describing: defaults()))")

        // `cmux space set-defaults --env '{"B":"2"}'`: env alone keeps the directory.
        let env = ActionInvocation(target: target, arguments: ["env": .string(#"{"B":"2"}"#)], origin: .cli)
        #expect(services.registry.perform("space.setDefaults", invocation: env))
        await wait(within: .seconds(30)) { defaults()?.env == ["B": "2"] }
        #expect(defaults()?.env == ["B": "2"])
        #expect(defaults()?.cwd == "/tmp/other", "--env alone dropped the space's directory: \(String(describing: defaults()))")

        // `--cwd=` alone clears only the directory.
        let noCwd = ActionInvocation(target: target, arguments: ["cwd": .string("")], origin: .cli)
        #expect(services.registry.perform("space.setDefaults", invocation: noCwd))
        await wait(within: .seconds(30)) { defaults()?.cwd == nil }
        #expect(defaults()?.cwd == nil)
        #expect(defaults()?.env == ["B": "2"], "--cwd= alone dropped the space's environment: \(String(describing: defaults()))")

        // Two quick partial runs, the second sent before the mirror shows the first: each merges into
        // what the daemon holds when it runs, so neither drops the other's field.
        let quickCwd = ActionInvocation(target: target, arguments: ["cwd": .string("/tmp/a")], origin: .cli)
        let quickEnv = ActionInvocation(target: target, arguments: ["env": .string(#"{"X":"1"}"#)], origin: .cli)
        #expect(services.registry.perform("space.setDefaults", invocation: quickCwd))
        #expect(services.registry.perform("space.setDefaults", invocation: quickEnv))
        await wait(within: .seconds(30)) { defaults() == ProfileDefaults(cwd: "/tmp/a", env: ["X": "1"]) }
        #expect(defaults() == ProfileDefaults(cwd: "/tmp/a", env: ["X": "1"]),
                "back-to-back --cwd and --env lost a field: \(String(describing: defaults()))")

        // `cmux space clear-defaults --confirm` removes both.
        let clear = ActionInvocation(target: target, origin: .cli).confirmed()
        #expect(services.registry.perform("space.clearDefaults", invocation: clear))
        await wait(within: .seconds(30)) { defaults()?.isEmpty ?? true }
        #expect(defaults()?.isEmpty ?? true, "Clear Space Terminal Defaults left \(String(describing: defaults()))")
    }
}
