import CMUXAgentLaunch
import Darwin
import Dispatch
import Foundation
import Testing

@Suite("AgentHookStateLocation")
struct AgentHookStateLocationTests {
    @Test("Scopes hook state by sanitized bundle identifier")
    func scopesHookStateByBundleIdentifier() throws {
        let applicationSupport = URL(fileURLWithPath: "/tmp/cmux application support", isDirectory: true)

        let location = try #require(AgentHookStateLocation(
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: " com.cmuxterm.app.debug.restore/test "
        ))

        #expect(
            location.directoryURL
                == applicationSupport
                    .appendingPathComponent("cmux", isDirectory: true)
                    .appendingPathComponent("agent-hooks", isDirectory: true)
                    .appendingPathComponent("com.cmuxterm.app.debug.restore-test", isDirectory: true)
        )
    }

    @Test("Rejects a blank bundle identifier")
    func rejectsBlankBundleIdentifier() {
        #expect(AgentHookStateLocation(
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            bundleIdentifier: "  "
        ) == nil)
    }

    @Test("Prefers an explicit hook state directory")
    func resolvesEnvironmentOverride() {
        let directory = AgentHookStateLocation(
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": "~/hook-state"],
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/app-support", isDirectory: true),
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        ).directoryURL

        #expect(directory.path == NSString(string: "~/hook-state").expandingTildeInPath)
    }

    @Test("Uses the bundle scope when no override exists")
    func resolvesBundleScope() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)
        let directory = AgentHookStateLocation(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        ).directoryURL

        #expect(
            directory
                == applicationSupport
                    .appendingPathComponent("cmux", isDirectory: true)
                    .appendingPathComponent("agent-hooks", isDirectory: true)
                    .appendingPathComponent("com.cmuxterm.app.nightly", isDirectory: true)
        )
    }

    @Test("Hook writers inherit the bundle scope from existing terminal environments")
    func preUpgradeHookWriterUsesInheritedBundleScope() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)
        let location = AgentHookStateWriterLocation(
            environment: ["CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly"],
            applicationSupportDirectory: applicationSupport,
            containingBundleIdentifier: nil,
            legacyHomeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )

        #expect(
            location.directoryURL
                == applicationSupport
                    .appendingPathComponent("cmux", isDirectory: true)
                    .appendingPathComponent("agent-hooks", isDirectory: true)
                    .appendingPathComponent("com.cmuxterm.app.nightly", isDirectory: true)
        )
    }

    @Test("Falls back to the legacy directory without a bundle scope")
    func resolvesLegacyFallback() {
        let home = URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        let directory = AgentHookStateLocation(
            environment: [:],
            applicationSupportDirectory: nil,
            bundleIdentifier: nil,
            legacyHomeDirectory: home
        ).directoryURL

        #expect(directory == home.appendingPathComponent(".cmuxterm", isDirectory: true))
    }

    @Test("Migrates legacy hook state once for a production channel")
    func migratesLegacyStateOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-state-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root.appendingPathComponent("app-support", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let legacy = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        let scoped = applicationSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-hooks", isDirectory: true)
            .appendingPathComponent("com.cmuxterm.app.nightly", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let filename = "codex-hook-sessions.json"
        let legacyFile = legacy.appendingPathComponent(filename, isDirectory: false)
        let legacyData = Data(#"{"sessions":{"legacy":{"workspaceId":"legacy"}}}"#.utf8)
        try legacyData.write(to: legacyFile)

        let location = AgentHookStateReaderLocation(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: home,
            fileManager: .default
        )

        #expect(location.directoryURL == scoped)
        #expect(try Data(contentsOf: scoped.appendingPathComponent(filename)) == legacyData)

        try Data(#"{"sessions":{"new":{"workspaceId":"new"}}}"#.utf8).write(to: legacyFile)
        _ = AgentHookStateReaderLocation(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: home,
            fileManager: .default
        )
        #expect(try Data(contentsOf: scoped.appendingPathComponent(filename)) == legacyData)
    }

    @Test("Keeps an explicit reader override isolated")
    func explicitReaderOverrideDoesNotMigrateLegacyState() {
        let override = URL(fileURLWithPath: "/tmp/custom-hook-state", isDirectory: true)

        let location = AgentHookStateReaderLocation(
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": override.path],
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/app-support", isDirectory: true),
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            fileManager: .default
        )

        #expect(location.directoryURL == override)
    }

    @Test("Migration preserves scoped records and imports missing legacy sessions")
    func migrationPrefersScopedRecords() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-state-precedence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root.appendingPathComponent("app-support", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let legacy = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        let scoped = applicationSupport
            .appendingPathComponent("cmux/agent-hooks/com.cmuxterm.app.nightly", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
        let filename = "codex-hook-sessions.json"
        let legacyPayload: [String: Any] = [
            "version": 1,
            "sessions": [
                "duplicate": ["workspaceId": "legacy"],
                "legacy-only": ["workspaceId": "legacy-only"],
            ],
            "activeSessionsByWorkspace": [
                "duplicate-workspace": ["sessionId": "legacy"],
                "legacy-workspace": ["sessionId": "legacy-only"],
            ],
            "activeSessionsBySurface": [
                "duplicate-surface": ["sessionId": "legacy"],
                "legacy-surface": ["sessionId": "legacy-only"],
            ],
        ]
        let scopedPayload: [String: Any] = [
            "version": 1,
            "sessions": [
                "duplicate": ["workspaceId": "scoped"],
                "scoped-only": ["workspaceId": "scoped-only"],
            ],
            "activeSessionsByWorkspace": [
                "duplicate-workspace": ["sessionId": "scoped"],
                "scoped-workspace": ["sessionId": "scoped-only"],
            ],
            "activeSessionsBySurface": [
                "duplicate-surface": ["sessionId": "scoped"],
                "scoped-surface": ["sessionId": "scoped-only"],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacyPayload).write(
            to: legacy.appendingPathComponent(filename)
        )
        try JSONSerialization.data(withJSONObject: scopedPayload).write(
            to: scoped.appendingPathComponent(filename)
        )

        _ = AgentHookStateReaderLocation(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: home,
            fileManager: .default
        )

        let data = try Data(contentsOf: scoped.appendingPathComponent(filename))
        let rootObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try #require(rootObject["sessions"] as? [String: Any])
        #expect((sessions["duplicate"] as? [String: Any])?["workspaceId"] as? String == "scoped")
        #expect((sessions["legacy-only"] as? [String: Any])?["workspaceId"] as? String == "legacy-only")
        #expect((sessions["scoped-only"] as? [String: Any])?["workspaceId"] as? String == "scoped-only")
        let activeWorkspaces = try #require(rootObject["activeSessionsByWorkspace"] as? [String: Any])
        #expect((activeWorkspaces["duplicate-workspace"] as? [String: Any])?["sessionId"] as? String == "scoped")
        #expect((activeWorkspaces["legacy-workspace"] as? [String: Any])?["sessionId"] as? String == "legacy-only")
        #expect((activeWorkspaces["scoped-workspace"] as? [String: Any])?["sessionId"] as? String == "scoped-only")
        let activeSurfaces = try #require(rootObject["activeSessionsBySurface"] as? [String: Any])
        #expect((activeSurfaces["duplicate-surface"] as? [String: Any])?["sessionId"] as? String == "scoped")
        #expect((activeSurfaces["legacy-surface"] as? [String: Any])?["sessionId"] as? String == "legacy-only")
        #expect((activeSurfaces["scoped-surface"] as? [String: Any])?["sessionId"] as? String == "scoped-only")
    }

    @Test("Does not import shared legacy state into tagged debug builds")
    func taggedDebugReaderDoesNotMigrateLegacyState() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)
        let location = AgentHookStateReaderLocation(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.debug.restore-test",
            legacyHomeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            fileManager: .default
        )

        #expect(
            location.directoryURL
                == applicationSupport
                    .appendingPathComponent("cmux", isDirectory: true)
                    .appendingPathComponent("agent-hooks", isDirectory: true)
                    .appendingPathComponent("com.cmuxterm.app.debug.restore-test", isDirectory: true)
        )
    }

    @Test("Concurrent readers serialize the first migration")
    func concurrentReadersSerializeMigration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-state-concurrent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root.appendingPathComponent("app-support", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let legacy = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        let scoped = applicationSupport
            .appendingPathComponent("cmux/agent-hooks/com.cmuxterm.app.nightly", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let filename = "codex-hook-sessions.json"
        let legacyData = Data(#"{"sessions":{"legacy":{"workspaceId":"legacy"}}}"#.utf8)
        try legacyData.write(to: legacy.appendingPathComponent(filename))

        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            _ = AgentHookStateReaderLocation(
                environment: [:],
                applicationSupportDirectory: applicationSupport,
                bundleIdentifier: "com.cmuxterm.app.nightly",
                legacyHomeDirectory: home,
                fileManager: .default
            )
        }

        #expect(FileManager.default.fileExists(
            atPath: scoped.appendingPathComponent(".legacy-hook-state-migration.lock").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: scoped.appendingPathComponent(".legacy-hook-state-migrated-v1").path
        ))
        #expect(try Data(contentsOf: scoped.appendingPathComponent(filename)) == legacyData)
    }

    @Test("Migration coordinates with concurrent hook writers")
    func migrationCoordinatesWithHookWriterLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-state-writer-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root.appendingPathComponent("app-support", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let legacy = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        let scoped = applicationSupport
            .appendingPathComponent("cmux/agent-hooks/com.cmuxterm.app.nightly", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
        let filename = "codex-hook-sessions.json"
        let legacyFile = legacy.appendingPathComponent(filename)
        let scopedFile = scoped.appendingPathComponent(filename)
        try JSONSerialization.data(withJSONObject: [
            "sessions": ["legacy-only": ["workspaceId": "legacy"]],
        ]).write(to: legacyFile)
        try JSONSerialization.data(withJSONObject: [
            "sessions": ["before-writer": ["workspaceId": "before"]],
        ]).write(to: scopedFile)

        let lockFile = scoped.appendingPathComponent(filename + ".lock")
        let lockDescriptor = lockFile.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR) } ?? -1
        }
        #expect(lockDescriptor >= 0)
        defer { close(lockDescriptor) }
        #expect(flock(lockDescriptor, LOCK_EX) == 0)

        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            _ = AgentHookStateReaderLocation(
                environment: [:],
                applicationSupportDirectory: applicationSupport,
                bundleIdentifier: "com.cmuxterm.app.nightly",
                legacyHomeDirectory: home,
                fileManager: .default
            )
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 1) == .success)
        #expect(finished.wait(timeout: .now() + 1) == .timedOut)

        try JSONSerialization.data(withJSONObject: [
            "sessions": ["writer-update": ["workspaceId": "writer"]],
        ]).write(to: scopedFile, options: .atomic)
        #expect(flock(lockDescriptor, LOCK_UN) == 0)
        #expect(finished.wait(timeout: .now() + 2) == .success)

        let data = try Data(contentsOf: scopedFile)
        let rootObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try #require(rootObject["sessions"] as? [String: Any])
        #expect((sessions["legacy-only"] as? [String: Any])?["workspaceId"] as? String == "legacy")
        #expect((sessions["writer-update"] as? [String: Any])?["workspaceId"] as? String == "writer")
    }

    @Test("Malformed legacy stores leave migration pending for a later retry")
    func malformedLegacyStoreRetriesAfterRepair() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hook-state-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationSupport = root.appendingPathComponent("app-support", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let legacy = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        let scoped = applicationSupport
            .appendingPathComponent("cmux/agent-hooks/com.cmuxterm.app.nightly", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let filename = "codex-hook-sessions.json"
        let legacyFile = legacy.appendingPathComponent(filename)
        let marker = scoped.appendingPathComponent(".legacy-hook-state-migrated-v1")
        try Data("{".utf8).write(to: legacyFile)

        _ = AgentHookStateReaderLocation(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: home,
            fileManager: .default
        )
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        try Data(#"{"sessions":{"repaired":{"workspaceId":"workspace"}}}"#.utf8).write(
            to: legacyFile,
            options: .atomic
        )
        _ = AgentHookStateReaderLocation(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: home,
            fileManager: .default
        )

        #expect(FileManager.default.fileExists(atPath: marker.path))
        let data = try Data(contentsOf: scoped.appendingPathComponent(filename))
        let rootObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try #require(rootObject["sessions"] as? [String: Any])
        #expect((sessions["repaired"] as? [String: Any])?["workspaceId"] as? String == "workspace")
    }

    @Test("Sanitizes non-ASCII bundle identifier characters")
    func sanitizesUnicodeBundleIdentifierCharacters() throws {
        let location = try #require(AgentHookStateLocation(
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/app-support", isDirectory: true),
            bundleIdentifier: "com.猫.app"
        ))

        #expect(location.directoryURL.lastPathComponent == "com.-.app")
    }
}
