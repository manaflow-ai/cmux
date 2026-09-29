import Foundation
import Testing
@testable import CmuxNextDaemon

/// One isolated daemon (own session and state dir) from the branch binary,
/// with a connection and a store mirroring it.
struct BranchDaemonHarness {
    let root: URL
    let session: String
    let endpoint: DaemonEndpoint
    let identity: DaemonIdentity
    let connection: DaemonConnection
    let store: DaemonStore
    private let storeTask: Task<Void, Never>

    static func start(
        daemonEnvironment: [String: String]? = nil,
        terminalEnvironment: (@Sendable () async -> [String: String])? = nil
    ) async throws -> BranchDaemonHarness {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-bd-\(id)")
        let session = "cnd-bd-\(id)"
        let base = ProcessInfo.processInfo.environment
        let environment = daemonEnvironment ?? LoginEnvironment.daemonEnvironment(login: nil, base: base, overrides: [:])
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { environment })
        let ensured = try await launcher.ensure()
        let connection = DaemonConnection(
            configuration: DaemonConnection.Configuration(terminalEnvironment: terminalEnvironment),
            endpointProvider: launcher.endpointProvider)
        let identity = try await connection.start()
        let store = await DaemonStore()
        let storeTask = Task { await store.run(connection: connection) }
        return BranchDaemonHarness(root: root, session: session, endpoint: ensured.endpoint, identity: identity,
                                   connection: connection, store: store, storeTask: storeTask)
    }

    func stop() async {
        storeTask.cancel()
        try? await connection.shutdownDaemon()
        await connection.close()
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs `body`, then stops the daemon whether or not it threw.
    static func with(
        daemonEnvironment: [String: String]? = nil,
        terminalEnvironment: (@Sendable () async -> [String: String])? = nil,
        _ body: (BranchDaemonHarness) async throws -> Void
    ) async throws {
        let harness = try await start(daemonEnvironment: daemonEnvironment, terminalEnvironment: terminalEnvironment)
        do {
            try await body(harness)
        } catch {
            await harness.stop()
            throw error
        }
        await harness.stop()
    }

    /// A workspace with one terminal; returns its key, pane, and surface.
    func workspaceWithTerminal(_ name: String) async throws -> (key: WorkspaceKey, pane: PaneID, surface: SurfaceID) {
        let workspace = try await connection.createWorkspace(name: name)
        let terminal = try await connection.createTerminal(in: workspace.key, cwd: root.path, size: CellSize(cols: 120, rows: 30))
        let surface = try #require(terminal.surface)
        let pane = try #require(terminal.pane)
        return (workspace.key, pane, surface)
    }

    /// The current tree straight from the daemon.
    func tree() async throws -> DaemonTree { try await connection.listWorkspaces() }

    func tab(_ surface: SurfaceID) async throws -> TabSnapshot? {
        try await tree().workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first { $0.surface == surface }
    }

    func pane(of surface: SurfaceID) async throws -> PaneSnapshot? {
        try await tree().workspaces.flatMap(\.screens).flatMap(\.panes).first { $0.tabs.contains { $0.surface == surface } }
    }

    func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: @Sendable () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DaemonError.timedOut(what)
    }

    /// Types `command` into `surface` and returns output up to `sentinel`.
    func run(_ command: String, in surface: SurfaceID, until sentinel: String) async throws -> String {
        let attachment = try await TerminalAttachment.attach(
            endpoint: endpoint,
            target: .init(surface: surface, generation: identity.generation),
            size: CellSize(cols: 200, rows: 50), claimGeometry: true)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            await attachment.detach()
        }
        await attachment.write(Data((command + "\r").utf8))
        var output = ""
        for await event in attachment.events {
            guard case .output(let data, _) = event else { continue }
            output += String(decoding: data, as: UTF8.self)
            if output.contains(sentinel) { break }
        }
        watchdog.cancel()
        await attachment.detach()
        return output
    }
}
