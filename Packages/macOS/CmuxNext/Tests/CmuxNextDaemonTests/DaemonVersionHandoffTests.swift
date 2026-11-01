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

/// The version handoff's rule: which running owner is another build than the bundled binary.
/// Pure: no daemon runs.
struct DaemonVersionDecisionTests {
    private func decide(_ running: DaemonBuildStamp, _ bundled: DaemonBuildStamp?) -> DaemonVersionDecision {
        DaemonLauncher.versionDecision(running: running, bundled: bundled)
    }

    /// Two packaged builds: `build_id` is the stamped commit.
    @Test func stampedBuildsCompareByBuild() {
        let abc = DaemonBuildStamp(commit: "abc1234", id: "abc1234")
        let def = DaemonBuildStamp(commit: "def5678", id: "def5678")
        #expect(decide(abc, abc) == .keep("same build"))
        #expect(decide(abc, def) == .restart(running: "abc1234", bundled: "def5678"))
    }

    /// An owner older than `daemon-build-v1` reports no `build_id`: the stamped commits decide.
    @Test func anOwnerWithoutBuildIDComparesCommits() {
        let old = DaemonBuildStamp(commit: "abc1234", id: nil)
        #expect(decide(old, DaemonBuildStamp(commit: "abc1234", id: "abc1234")) == .keep("same build"))
        #expect(decide(old, DaemonBuildStamp(commit: "def5678", id: "def5678"))
            == .restart(running: "abc1234", bundled: "def5678"))
    }

    /// Two unstamped builds of one commit with different uncommitted edits: no `build_commit`, and
    /// `build_id` carries the dirty hash. The owner runs the other edits, so it is handed off. On
    /// the code before this fix the null commit kept it with no notice ("running build unknown").
    @Test func aDirtyBuildOfTheSameCommitIsHandedOff() {
        let running = DaemonBuildStamp(commit: nil, id: "abc1234-dirty.aaaa")
        let bundled = DaemonBuildStamp(commit: nil, id: "abc1234-dirty.bbbb")
        #expect(decide(running, bundled) == .restart(running: "abc1234-dirty.aaaa", bundled: "abc1234-dirty.bbbb"))
        #expect(decide(running, running) == .keep("same build"))
    }

    /// One commit stamped on both, but the identities differ: the identity decides, not the commit.
    @Test func theBuildIDDecidesOverTheCommit() {
        let running = DaemonBuildStamp(commit: "abc1234", id: "abc1234-dirty.aaaa")
        let bundled = DaemonBuildStamp(commit: "abc1234", id: "abc1234-dirty.bbbb")
        #expect(decide(running, bundled) == .restart(running: "abc1234-dirty.aaaa", bundled: "abc1234-dirty.bbbb"))
    }

    /// When nothing can be compared the owner is kept, and the reason says which side is unknown.
    @Test func anUnknownBuildIsKeptWithItsReason() {
        let known = DaemonBuildStamp(commit: "abc1234", id: "abc1234")
        #expect(decide(DaemonBuildStamp(commit: nil, id: nil), known) == .keep("running build unknown"))
        #expect(decide(known, nil) == .keep("bundled build unknown"))
        #expect(decide(known, DaemonBuildStamp(commit: nil, id: nil)) == .keep("bundled build unknown"))
    }

    /// `cmux --version --json` and `identify` give the same two fields.
    @Test func theStampReadsTheVersionJSONAndIdentify() throws {
        let json = Data(#"{"app":"cmux-tui","build_identity":"abc1234-dirty.aaaa","build_commit":null}"#.utf8)
        #expect(DaemonBuildStamp(versionJSON: json) == DaemonBuildStamp(commit: nil, id: "abc1234-dirty.aaaa"))
        #expect(DaemonBuildStamp(versionJSON: Data("cmux 0.1.0".utf8)) == nil)
        let identity = DaemonIdentity(buildCommit: "", buildID: "abc1234", generation: DaemonGeneration(rawValue: "stamp-test"))
        #expect(DaemonBuildStamp(identity: identity) == DaemonBuildStamp(commit: nil, id: "abc1234"))
    }
}
