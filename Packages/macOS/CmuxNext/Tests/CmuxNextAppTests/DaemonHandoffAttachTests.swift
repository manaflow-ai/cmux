import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// After an update the app finds the daemon its previous build started and
/// hands it off to the bundled build. The app attaches to the new daemon
/// only: it never mirrors the old one and then drops every view for a
/// reconnect a moment later.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct DaemonHandoffAttachTests {
    @Test func anUpdatedAppAttachesOnlyToTheHandedOffDaemon() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cn-handoff-\(id)")
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-handoff-\(id)", stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        defer { try? FileManager.default.removeItem(at: root) }

        // The previous build's daemon, with a running terminal.
        let old = try await launcher.ensure()
        let seed = DaemonConnection(endpoint: DaemonEndpoint(socketPath: old.socket))
        let terminal: CreateTerminalResult
        do {
            _ = try await seed.start()
            let workspace = try await seed.createWorkspace(name: "kept")
            terminal = try await seed.createTerminal(in: workspace.key, cwd: root.path, size: CellSize(cols: 80, rows: 24))
            await seed.close()
        } catch {
            await seed.close()
            await Self.shutDown(launcher)
            throw error
        }

        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        services.daemon.start(handOff: { connection, identity in
            // As if the app had been updated to another build.
            if case .restart = await launcher.handOffIfStale(identity: identity, using: connection, bundled: DaemonBuildStamp(commit: "0000000", id: "0000000")) {
                return true
            }
            return false
        }) {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        let store = services.daemon.store

        // Bounded test-only poll for the new daemon's mirror.
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            if let pid = store.identity?.pid, pid != old.pid, store.workspaces.contains(where: { $0.name == "kept" }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Give a late reconnect time to show; test-only wait.
        try await Task.sleep(for: .seconds(1))
        let attachedPid = store.identity?.pid
        let epoch = store.connectionEpoch
        let kept = store.workspaces.first { $0.name == "kept" }
        let terminals = kept?.screens.flatMap(\.panes).flatMap(\.tabs).compactMap(\.terminalID) ?? []

        services.daemon.shutdownConnection()
        for controller in services.windows.controllers { controller.window?.close() }
        await Self.shutDown(launcher)

        #expect(attachedPid != nil && attachedPid != old.pid, "the app stayed on the old daemon")
        #expect(epoch == 1, "the app attached to the old daemon, then reconnected (epoch \(epoch))")
        #expect(terminals.contains(terminal.terminalID), "the terminal did not survive the handoff")
    }

    /// Ends the session's daemon and its terminals, whichever build runs.
    private static func shutDown(_ launcher: DaemonLauncher) async {
        guard let running = try? await launcher.ensure() else { return }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: running.socket))
        if (try? await connection.start()) != nil {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: running.pid, generation: running.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }
        await connection.close()
    }
}
