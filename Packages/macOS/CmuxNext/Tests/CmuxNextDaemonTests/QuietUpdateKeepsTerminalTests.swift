import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// The quiet restart of a stale local cmux-tui (`QuietDaemonUpdate` in the app): it waits while a
/// client that does not reconnect is attached (a `cmux` CLI call in flight names no kind, cmux-tui
/// cli), restarts on that client's `client-detached`, and the terminal keeps running: its host is
/// the same process and the new owner lists the same terminal. The app's own `frontend`
/// connections and the daemon's standing SDK connections (its agent screen detector names no kind
/// either) do not hold it back (`OwnerIdleProbe.Clients.reconnecting`). A real daemon.
@Suite(.enabled(if: RealBinary.url != nil, "no cmux-tui binary available"), .liveDaemon, .timeLimit(.minutes(3)))
struct QuietUpdateKeepsTerminalTests {
    @Test func theQuietRestartWaitsForACLICallAndKeepsTheTerminalRunning() async throws {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-quiet-\(id)")
        let state = root.appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ProcessInfo.processInfo.environment
        let environment = LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:])
        // As the app's launcher: the bundled binary, so the update handoff applies.
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cnd-quiet-\(id)", stateDirectory: state, binaryIsBundled: true),
            environment: { environment })
        let owner = DaemonConnection(endpointProvider: launcher.endpointProvider)
        var cli: DaemonConnection?
        do {
            _ = try await launcher.ensure()
            let old = try await owner.start()
            let workspace = try await owner.createWorkspace(name: "kept")
            let terminal = try await owner.createTerminal(in: workspace.key, cwd: root.path, size: CellSize(cols: 80, rows: 24))
            let hostsBefore = TerminalHosts.terminals(daemon: old.pid, state: state)
            #expect(!hostsBefore.isEmpty, "no terminal host for the new terminal")

            // Another app-style connection (kind `frontend`, as each terminal view's) does not hold the restart.
            let endpoint = try #require(await owner.endpoint)
            let view = DaemonConnection(endpoint: endpoint, configuration: .init(clientName: "cmux-next-terminal"))
            _ = try await view.start()
            // The daemon's own clients without a kind (its agent screen detector) are standing
            // connections once older than a call's time, as in the app, where they are minutes old.
            try await Self.waitForStandingClients(of: owner, olderThan: Self.callSeconds)
            // A CLI call in flight: a client that names no kind.
            let call = DaemonConnection(endpoint: endpoint, configuration: .init(clientName: "cmux"))
            cli = call
            _ = try await call.start()
            let cleared = try await call.resourceRequest({ rid in
                ResourceRequestEnvelope(id: rid, operation: "client.metadata.update",
                                        params: ["client": .string("current"), "kind": .null])
            }, as: JSONValue.self)
            #expect(cleared["client_kind"] == .null, "\(cleared)")

            let probe = OwnerIdleProbe(owner, clients: .reconnecting, callSeconds: Self.callSeconds)
            let restart = IdleOwnerRestart(isIdle: { await probe.isIdle() }) {
                await launcher.handOffForUpdate(identity: old, using: owner)
            }
            #expect(await restart.attempt() == .waiting)
            #expect(await owner.identity?.pid == old.pid, "the owner restarted under a CLI call")

            // The call ends; its `client-detached` runs the restart.
            await call.close()
            cli = nil
            let outcome = try await Self.firstOutcome(of: restart, on: owner, timeout: .seconds(30))
            let busy = outcome == .started ? "" : await Self.busyReport(owner)
            #expect(outcome == .started, "still busy: \(busy)")
            await view.close()

            let deadline = ContinuousClock.now + .seconds(60)
            var current = await owner.identity
            var ready = await owner.isReady
            while current?.pid == old.pid || current == nil || !ready {
                if ContinuousClock.now >= deadline { break }
                try await Task.sleep(for: .milliseconds(100))  // test harness poll of the reconnect
                current = await owner.identity
                ready = await owner.isReady
            }
            #expect(current != nil && current?.pid != old.pid, "no new owner took over")
            // The same terminal, on the same host process.
            let listed = try await owner.listTerminals()
            #expect(listed.contains { $0.terminalID == terminal.terminalID.rawValue }, "the terminal did not survive: \(listed)")
            for host in hostsBefore {
                #expect(kill(host, 0) == 0, "terminal host \(host) ended with the old owner")
            }
            #expect(TerminalHosts.published(state: state).isSuperset(of: hostsBefore))
        } catch {
            await cli?.close()
            await BranchDaemonHarness.shutDown(owner)
            throw error
        }
        await BranchDaemonHarness.shutDown(owner)
    }

    /// How long a client without a kind counts as a call in flight here (a minute in the app).
    private static let callSeconds: Double = 10

    /// Waits until every other local client without a kind has been connected `seconds`.
    private static func waitForStandingClients(of owner: DaemonConnection, olderThan seconds: Double) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            let clients = try await owner.resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "client.list", params: [:])
            }, as: JSONValue.self)
            let young = (clients.arrayValue ?? []).filter { client in
                client["self"]?.boolValue != true && client["client_kind"]?.stringValue == nil
                    && (client["connected_seconds"]?.stringValue.flatMap(Double.init) ?? 0) < seconds
            }
            if young.isEmpty { return }
            try #require(ContinuousClock.now < deadline, "clients still young: \(young)")
            try await Task.sleep(for: .milliseconds(250))  // test harness poll of the clients' age
        }
    }

    /// What the idle probe reads (`client.list`, `conversation.list`), for a restart that never came.
    private static func busyReport(_ owner: DaemonConnection) async -> String {
        var report: [String] = []
        for operation in ["client.list", "conversation.list"] {
            let value = try? await owner.resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: operation, params: [:])
            }, as: JSONValue.self)
            report.append("\(operation): \(value.map { "\($0)" } ?? "unreadable")")
        }
        return report.joined(separator: "; ")
    }

    /// Feeds the owner's events to `restart` until it leaves `.waiting`; `.waiting` when no
    /// event moved it within `timeout`.
    private static func firstOutcome(of restart: IdleOwnerRestart, on owner: DaemonConnection,
                                     timeout: Duration) async throws -> IdleOwnerRestart.Outcome {
        try await withThrowingTaskGroup(of: IdleOwnerRestart.Outcome.self) { group in
            group.addTask {
                for try await envelope in owner.events {
                    let outcome = await restart.note(envelope.event)
                    if outcome != .waiting { return outcome }
                }
                return await restart.outcome
            }
            group.addTask {
                try await Task.sleep(for: timeout)  // test harness bound for an event that never comes
                return await restart.outcome
            }
            let first = try await group.next() ?? .waiting
            group.cancelAll()
            return first
        }
    }
}
