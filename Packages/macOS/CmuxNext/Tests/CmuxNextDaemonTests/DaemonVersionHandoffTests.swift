import Foundation
import Testing
@testable import CmuxNextDaemon

/// UP (plans/cmux-next/durable-sessions.md section 3): an updated app finds
/// the daemon its previous build started. It must hand that daemon off to
/// the bundled build, and every running terminal must survive the handoff.
/// Runs with any cmux-tui binary: the launcher passes only the `server
/// ensure` options the binary lists (LauncherReapGraceCapabilityTests).
@Suite(.enabled(if: RealBinary.url != nil, "no cmux-tui binary available"), .liveDaemon)
struct DaemonVersionHandoffTests {
    @Test func aDaemonOfAnotherBuildIsReplacedAndItsTerminalsSurvive() async throws {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-up-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ProcessInfo.processInfo.environment
        let environment = LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:])
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cnd-up-\(id)", stateDirectory: root.appendingPathComponent("state")),
            environment: { environment })
        _ = try await launcher.ensure()
        let connection = DaemonConnection(endpointProvider: launcher.endpointProvider)
        let old = try await connection.start()
        do {
            let workspace = try await connection.createWorkspace(name: "up")
            let terminal = try await connection.createTerminal(in: workspace.key, cwd: root.path,
                                                               size: CellSize(cols: 80, rows: 24))
            let terminalID = terminal.terminalID.rawValue

            // The same build is never handed off.
            let build = DaemonBuildStamp(identity: old)
            let running = try #require(build.id ?? build.commit)
            #expect(await launcher.handOffIfStale(identity: old, using: connection, bundled: build)
                == .keep("same build"))

            // As if the app had been updated to another build.
            let decision = await launcher.handOffIfStale(identity: old, using: connection, bundled: Self.otherBuild)
            #expect(decision == .restart(running: running, bundled: "0000000"))

            // The connection reconnects to the new daemon by itself.
            let deadline = ContinuousClock.now + .seconds(60)
            var current = await connection.identity
            while current?.pid == old.pid || current == nil {
                #expect(ContinuousClock.now < deadline, "no new daemon took over")
                if ContinuousClock.now >= deadline { break }
                try await Task.sleep(for: .milliseconds(100))
                current = await connection.identity
            }
            #expect(current?.pid != old.pid)
            #expect(current?.registryID == old.registryID, "the new daemon must open the same session state")

            // The terminal is the same terminal, still running.
            let entries = try await connection.listTerminals()
            let entry = try #require(entries.first { $0.terminalID == terminalID })
            #expect(entry.lifecycle == "running", "\(entry)")

            // A second handoff to the same bundled build is not repeated.
            let again = await launcher.handOffIfStale(identity: try #require(current), using: connection,
                                                      bundled: Self.otherBuild)
            #expect(again == .keep("already handed off to 0000000"))
        } catch {
            await BranchDaemonHarness.shutDown(connection)
            throw error
        }
        await BranchDaemonHarness.shutDown(connection)
    }

    /// An owner the handshake refuses (here: it lacks a capability the connecting app requires,
    /// as an owner of an older protocol does) is handed off the same way, and its terminals survive.
    @Test func anIncompatibleOwnerIsReplacedAndItsTerminalsSurvive() async throws {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-inc-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ProcessInfo.processInfo.environment
        let environment = LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:])
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cnd-inc-\(id)", stateDirectory: root.appendingPathComponent("state"),
                                 binaryIsBundled: true),
            environment: { environment })
        _ = try await launcher.ensure()
        let connection = DaemonConnection(endpointProvider: launcher.endpointProvider)
        let old = try await connection.start()
        do {
            let workspace = try await connection.createWorkspace(name: "inc")
            let terminal = try await connection.createTerminal(in: workspace.key, cwd: root.path,
                                                               size: CellSize(cols: 80, rows: 24))
            let terminalID = terminal.terminalID.rawValue

            // As if an updated app required a capability this owner never had.
            var required = DaemonConnection.Configuration(terminalEnvironment: nil)
            required.requiredCapabilities += ["cmux-test-never-served-v1"]
            let updated = DaemonConnection(configuration: launcher.handingOffIncompatibleOwners(required),
                                           endpointProvider: launcher.endpointProvider)
            await #expect(throws: DaemonError.incompatibleOwnerHandedOff) { _ = try await updated.start() }
            await updated.close()

            // The first connection reconnects to the successor by itself.
            let deadline = ContinuousClock.now + .seconds(60)
            var current = await connection.identity
            while current?.pid == old.pid || current == nil {
                #expect(ContinuousClock.now < deadline, "no new daemon took over")
                if ContinuousClock.now >= deadline { break }
                try await Task.sleep(for: .milliseconds(100))
                current = await connection.identity
            }
            #expect(current?.pid != old.pid)
            #expect(current?.registryID == old.registryID, "the new daemon must open the same session state")
            let entries = try await connection.listTerminals()
            let entry = try #require(entries.first { $0.terminalID == terminalID })
            #expect(entry.lifecycle == "running", "\(entry)")
        } catch {
            await BranchDaemonHarness.shutDown(connection)
            throw error
        }
        await BranchDaemonHarness.shutDown(connection)
    }

    /// Another build than any real one, as an updated app's bundle.
    static let otherBuild = DaemonBuildStamp(commit: "0000000", id: "0000000")
}
