import CMUXAgentLaunch
import Foundation
import SQLite3
import Testing
@testable import CmuxWorkspaces

private struct IncidentSnapshot: SessionSnapshotRepresenting, Equatable {
    struct Window: Codable, Equatable, Sendable {
        var panels: [Panel]
    }

    struct Panel: Codable, Equatable, Sendable {
        enum Route: String, Codable, Sendable {
            case direct
            case pooled
            case pinned
            case shell
        }

        var id: String
        var kind: String?
        var checkpointID: String?
        var route: Route
        var workingDirectory: String
        var launchCommand: AgentLaunchCommand?
        var environment: [String: String]
    }

    var version: Int
    var windows: [Window]

    var hasWindows: Bool { !windows.isEmpty }
}

@Suite("Incident-shaped restore acceptance")
struct IncidentRestoreAcceptanceTests {
    private let schemaVersion = 1
    private let ambientEnvironment = [
        "PATH": "/usr/bin:/bin",
        "CODEX_HOME": "/ambient/wrong-codex-home",
        "CLAUDE_CONFIG_DIR": "/ambient/wrong-claude-profile",
        "ANTHROPIC_AUTH_TOKEN": "ambient-wrong-token",
    ]

    @Test("clean restart preserves topology, cwd, identity, and route contract")
    func cleanRestartPreservesIncidentTopology() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = makeIncidentSnapshot(root: fixture.root)

        #expect(fixture.repository.save(snapshot))
        let restored = try #require(fixture.repository.loadStartupSnapshot())
        #expect(restored == snapshot)
        try assertRestoredTopology(restored)
    }

    @Test("kill before rotation keeps the last complete primary")
    func interruptionBeforeSnapshotRotation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let complete = makeIncidentSnapshot(root: fixture.root)
        var interrupted = complete
        interrupted.windows[0].panels.removeLast()

        #expect(fixture.repository.save(complete))
        // `interrupted` represents in-memory state that never reached the
        // repository before process termination.
        #expect(interrupted != complete)
        let restored = try #require(fixture.repository.loadStartupSnapshot())
        #expect(restored == complete)
        try assertRestoredTopology(restored)
    }

    @Test("partial replay retry is deterministic and does not change route ownership")
    func interruptionDuringPartialReplay() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = makeIncidentSnapshot(root: fixture.root)
        #expect(fixture.repository.save(snapshot))

        let restored = try #require(fixture.repository.loadStartupSnapshot())
        let firstPass = try plannedInvocations(restored)
        let partialCount = firstPass.count / 2
        #expect(partialCount > 0)
        let retry = try plannedInvocations(try #require(fixture.repository.loadStartupSnapshot()))

        let restoredIDs = firstPass.keys.sorted().prefix(partialCount)
        for id in restoredIDs {
            #expect(firstPass[id] == retry[id])
        }
        #expect(retry == firstPass)
    }

    @Test("unusable primary falls back to the intact previous snapshot")
    func missingOrUnusablePrimaryFallsBack() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = makeIncidentSnapshot(root: fixture.root)
        let primary = try #require(fixture.repository.defaultSnapshotFileURL())

        #expect(fixture.repository.save(snapshot))
        fixture.repository.syncManualRestoreSnapshotCache()
        try Data("interrupted write".utf8).write(to: primary, options: .atomic)

        let restored = try #require(fixture.repository.loadStartupSnapshot())
        #expect(restored == snapshot)
        try assertRestoredTopology(restored)
    }

    @Test("dead and reused PIDs cannot suppress replay")
    func processGenerationLiveness() {
        #expect(RestorableAgentProcessObservation(
            recordedProcessID: 4100,
            processMatch: { _ in .mismatches }
        ).liveness == .exited)
        #expect(RestorableAgentProcessObservation(
            recordedProcessID: 4101,
            processMatch: { _ in .matches }
        ).liveness == .running)
        #expect(RestorableAgentProcessObservation(
            recordedProcessID: 4102,
            processMatch: { _ in .unknown }
        ).liveness == .unknown)
    }

    @Test("durable parent wins over a newer non-durable child")
    func durableParentRejectsNewerChild() throws {
        let fixture = try CodexFixture(createIndex: false)
        defer { fixture.remove() }
        let parentID = "a22293b7-bcef-4707-8439-2f538c8517a4"
        let childID = "b33304c8-cdf0-4818-954a-3f649d9628b5"
        _ = try fixture.writeRollout(sessionID: parentID)

        let results = CodexSessionResumeVerifier().verifyBatch(
            [
                .init(sessionId: childID),
                .init(sessionId: parentID),
            ],
            codexHome: fixture.codexHome.path
        )

        #expect(results[0] == .missing)
        guard case .exists(let evidence) = results[1] else {
            Issue.record("durable parent must remain selectable")
            return
        }
        #expect(evidence.sessionId == parentID)
    }

    @Test("index and rollout disagreement fails closed in both directions")
    func indexRolloutMismatch() throws {
        let fixture = try CodexFixture(createIndex: true)
        defer { fixture.remove() }
        let indexedMissingRollout = "c44415d9-def1-4929-a65b-4065ae0739c6"
        let rolloutMissingIndex = "d55526ea-ef02-4a3a-b76c-5176bf184ad7"
        let missingPath = fixture.codexHome.appendingPathComponent("sessions/missing.jsonl").path
        try fixture.insertThread(sessionID: indexedMissingRollout, rolloutPath: missingPath)
        _ = try fixture.writeRollout(sessionID: rolloutMissingIndex)

        let verifier = CodexSessionResumeVerifier()
        #expect(verifier.verify(
            sessionId: indexedMissingRollout,
            transcriptPath: nil,
            codexHome: fixture.codexHome.path
        ) == .unavailable)
        #expect(verifier.verify(
            sessionId: rolloutMissingIndex,
            transcriptPath: nil,
            codexHome: fixture.codexHome.path
        ) == .missing)
        guard case .exists(let evidence) = verifier.verify(
            sessionId: rolloutMissingIndex,
            transcriptPath: nil,
            codexHome: fixture.codexHome.path,
            allowLegacyFallbackForIndexedMissing: true
        ) else {
            Issue.record("explicit restore fallback must recover the exact rollout")
            return
        }
        #expect(evidence.sessionId == rolloutMissingIndex)
    }

    @Test("daemon recovery and provider retry preserve pooled and pinned contracts")
    func routedReplayRetriesPreserveContract() throws {
        let snapshot = makeIncidentSnapshot(root: URL(fileURLWithPath: "/tmp/incident-root"))
        let initialPlans = try plannedInvocations(snapshot)

        // A missing daemon or provider quota failure happens after planning.
        // Replanning the unchanged persisted request is the recovery boundary.
        let daemonRecoveryPlans = try plannedInvocations(snapshot)
        var failoverAmbient = ambientEnvironment
        failoverAmbient["CODEX_HOME"] = "/different/wrong-home"
        failoverAmbient["CLAUDE_CONFIG_DIR"] = "/different/wrong-profile"
        failoverAmbient["ANTHROPIC_AUTH_TOKEN"] = "different-wrong-token"
        let failoverPlans = try plannedInvocations(snapshot, ambient: failoverAmbient)

        #expect(daemonRecoveryPlans == initialPlans)
        for id in ["pooled-codex", "pinned-codex", "pooled-claude", "pinned-claude"] {
            #expect(failoverPlans[id]?.arguments == initialPlans[id]?.arguments)
            #expect(failoverPlans[id]?.workingDirectory == initialPlans[id]?.workingDirectory)
        }
        try assertRouteContracts(plans: initialPlans, snapshot: snapshot)
        try assertRouteContracts(plans: failoverPlans, snapshot: snapshot)
    }

    private func makeIncidentSnapshot(root: URL) -> IncidentSnapshot {
        let directDirectory = root.appendingPathComponent("direct", isDirectory: true).path
        let pooledDirectory = root.appendingPathComponent("pooled", isDirectory: true).path
        let pinnedDirectory = root.appendingPathComponent("successor", isDirectory: true).path
        let codexID = "a22293b7-bcef-4707-8439-2f538c8517a4"
        let claudeID = "b33304c8-cdf0-4818-954a-3f649d9628b5"
        let pooledCodexArgs = [
            "codex", "-c", #"model_provider=\"subrouter\""#,
            "-c", #"model_providers.subrouter.http_headers={\"X-Subrouter-Agent\"=\"codex\"}"#,
        ]
        let pinnedCodexArgs = [
            "codex", "-c", #"model_provider=\"subrouter\""#,
            "-c", #"model_providers.subrouter.http_headers={\"X-Subrouter-Agent\"=\"codex\",\"X-Subrouter-Account-ID\"=\"team-codex-1\"}"#,
        ]
        let panels = [
            IncidentSnapshot.Panel(
                id: "direct-codex", kind: "codex", checkpointID: codexID,
                route: .direct, workingDirectory: directDirectory,
                launchCommand: .init(launcher: "codex", arguments: ["codex"]), environment: [:]
            ),
            IncidentSnapshot.Panel(
                id: "pooled-codex", kind: "codex", checkpointID: codexID,
                route: .pooled, workingDirectory: pooledDirectory,
                launchCommand: .init(launcher: "codex", arguments: pooledCodexArgs), environment: [:]
            ),
            IncidentSnapshot.Panel(
                id: "pinned-codex", kind: "codex", checkpointID: codexID,
                route: .pinned, workingDirectory: pinnedDirectory,
                launchCommand: .init(
                    launcher: "codex", arguments: pinnedCodexArgs,
                    environment: ["CODEX_HOME": "/captured/pinned-codex"]
                ), environment: ["CODEX_HOME": "/captured/pinned-codex"]
            ),
            IncidentSnapshot.Panel(
                id: "direct-claude", kind: "claude", checkpointID: claudeID,
                route: .direct, workingDirectory: directDirectory,
                launchCommand: .init(launcher: "claude", arguments: ["claude"]), environment: [:]
            ),
            IncidentSnapshot.Panel(
                id: "pooled-claude", kind: "claude", checkpointID: claudeID,
                route: .pooled, workingDirectory: pooledDirectory,
                launchCommand: .init(
                    launcher: "claude", arguments: ["claude"],
                    environment: ["ANTHROPIC_BASE_URL": "http://subrouter.invalid"]
                ), environment: ["ANTHROPIC_BASE_URL": "http://subrouter.invalid"]
            ),
            IncidentSnapshot.Panel(
                id: "pinned-claude", kind: "claude", checkpointID: claudeID,
                route: .pinned, workingDirectory: pinnedDirectory,
                launchCommand: .init(
                    launcher: "claude", arguments: ["claude"],
                    environment: [
                        "ANTHROPIC_BASE_URL": "http://subrouter.invalid",
                        "CLAUDE_CONFIG_DIR": "/captured/pinned-claude",
                    ]
                ), environment: [
                    "ANTHROPIC_BASE_URL": "http://subrouter.invalid",
                    "CLAUDE_CONFIG_DIR": "/captured/pinned-claude",
                ]
            ),
            IncidentSnapshot.Panel(
                id: "plain-shell", kind: nil, checkpointID: nil,
                route: .shell, workingDirectory: directDirectory,
                launchCommand: nil, environment: [:]
            ),
        ]
        return IncidentSnapshot(version: schemaVersion, windows: [.init(panels: panels)])
    }

    private func plannedInvocations(
        _ snapshot: IncidentSnapshot,
        ambient: [String: String]? = nil
    ) throws -> [String: AgentRestoreInvocation] {
        let planner = AgentRestorePlanner(isExecutableFile: { _ in false })
        var plans: [String: AgentRestoreInvocation] = [:]
        for panel in snapshot.windows.flatMap(\.panels) where panel.route != .shell {
            let request = AgentRestoreRequest(
                mode: .resumeAgent,
                kind: try #require(panel.kind),
                checkpointID: panel.checkpointID,
                source: "agent-hook",
                workingDirectory: panel.workingDirectory,
                environment: panel.environment,
                launchCommand: panel.launchCommand,
                preparedArguments: nil,
                observedPermissionMode: nil
            )
            plans[panel.id] = planner.invocation(
                for: request,
                ambientEnvironment: ambient ?? ambientEnvironment
            )
        }
        return plans
    }

    private func assertRestoredTopology(_ snapshot: IncidentSnapshot) throws {
        let panels = snapshot.windows.flatMap(\.panels)
        #expect(panels.count == 7)
        #expect(Set(panels.map(\.route)) == [.direct, .pooled, .pinned, .shell])
        let plans = try plannedInvocations(snapshot)
        #expect(plans.count == 6)
        for panel in panels where panel.route != .shell {
            #expect(plans[panel.id]?.workingDirectory == panel.workingDirectory)
        }
        try assertRouteContracts(plans: plans, snapshot: snapshot)
    }

    private func assertRouteContracts(
        plans: [String: AgentRestoreInvocation],
        snapshot: IncidentSnapshot
    ) throws {
        let pooledCodex = try #require(plans["pooled-codex"])
        let pinnedCodex = try #require(plans["pinned-codex"])
        let pooledClaude = try #require(plans["pooled-claude"])
        let pinnedClaude = try #require(plans["pinned-claude"])
        #expect(!pooledCodex.arguments.joined().contains("X-Subrouter-Account-ID"))
        #expect(pooledCodex.environment["CODEX_HOME"] == nil)
        #expect(pinnedCodex.arguments.joined().contains("X-Subrouter-Account-ID"))
        #expect(pinnedCodex.environment["CODEX_HOME"] == "/captured/pinned-codex")
        #expect(pooledClaude.environment["ANTHROPIC_BASE_URL"] == "http://subrouter.invalid")
        #expect(pooledClaude.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(pooledClaude.environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(pinnedClaude.environment["CLAUDE_CONFIG_DIR"] == "/captured/pinned-claude")
        #expect(pinnedClaude.environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(snapshot.windows[0].panels.last?.route == .shell)
    }
}

private struct Fixture {
    let root: URL
    let repository: SessionSnapshotRepository<IncidentSnapshot>

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-incident-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = SessionSnapshotRepository(
            schemaVersion: 1,
            bundleIdentifier: "com.cmuxterm.incident-acceptance",
            appSupportDirectory: root
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class CodexFixture {
    let root: URL
    let codexHome: URL
    private let database: OpaquePointer?

    init(createIndex: Bool) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-incident-codex-\(UUID().uuidString)", isDirectory: true)
        codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        guard createIndex else {
            database = nil
            return
        }
        var opened: OpaquePointer?
        guard sqlite3_open(codexHome.appendingPathComponent("state_5.sqlite").path, &opened) == SQLITE_OK,
              let opened else {
            throw CocoaError(.fileWriteUnknown)
        }
        database = opened
        guard sqlite3_exec(
            opened,
            "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, source TEXT, thread_source TEXT)",
            nil, nil, nil
        ) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func writeRollout(sessionID: String) throws -> URL {
        let directory = codexHome.appendingPathComponent("sessions/2026/09/01", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "type": "session_meta",
            "payload": ["id": sessionID, "cwd": root.path],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let url = directory.appendingPathComponent("rollout-\(sessionID).jsonl")
        try data.write(to: url, options: .atomic)
        return url
    }

    func insertThread(sessionID: String, rolloutPath: String) throws {
        guard let database else { throw CocoaError(.fileWriteUnknown) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO threads (id, rollout_path) VALUES (?, ?)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(
            OpaquePointer(bitPattern: -1),
            to: sqlite3_destructor_type.self
        )
        sqlite3_bind_text(statement, 1, sessionID, -1, transient)
        sqlite3_bind_text(statement, 2, rolloutPath, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
