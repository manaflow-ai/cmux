import CMUXAgentLaunch
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
        let directory = AgentHookStateLocation.resolveDirectoryURL(
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": "~/hook-state"],
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/app-support", isDirectory: true),
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )

        #expect(directory.path == NSString(string: "~/hook-state").expandingTildeInPath)
    }

    @Test("Uses the bundle scope when no override exists")
    func resolvesBundleScope() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)
        let directory = AgentHookStateLocation.resolveDirectoryURL(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )

        #expect(
            directory
                == applicationSupport
                    .appendingPathComponent("cmux", isDirectory: true)
                    .appendingPathComponent("agent-hooks", isDirectory: true)
                    .appendingPathComponent("com.cmuxterm.app.nightly", isDirectory: true)
        )
    }

    @Test("Falls back to the legacy directory without a bundle scope")
    func resolvesLegacyFallback() {
        let home = URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        let directory = AgentHookStateLocation.resolveDirectoryURL(
            environment: [:],
            applicationSupportDirectory: nil,
            bundleIdentifier: nil,
            legacyHomeDirectory: home
        )

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
        try Data("legacy".utf8).write(to: legacyFile)

        let location = AgentHookStateReaderLocation(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: home,
            fileManager: .default
        )

        #expect(location.directoryURL == scoped)
        #expect(try Data(contentsOf: scoped.appendingPathComponent(filename)) == Data("legacy".utf8))

        try Data("new legacy write".utf8).write(to: legacyFile)
        _ = AgentHookStateReaderLocation(
            environment: [:],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: home,
            fileManager: .default
        )
        #expect(try Data(contentsOf: scoped.appendingPathComponent(filename)) == Data("legacy".utf8))
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
        ]
        let scopedPayload: [String: Any] = [
            "version": 1,
            "sessions": [
                "duplicate": ["workspaceId": "scoped"],
                "scoped-only": ["workspaceId": "scoped-only"],
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

    @Test("Sanitizes non-ASCII bundle identifier characters")
    func sanitizesUnicodeBundleIdentifierCharacters() throws {
        let location = try #require(AgentHookStateLocation(
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/app-support", isDirectory: true),
            bundleIdentifier: "com.猫.app"
        ))

        #expect(location.directoryURL.lastPathComponent == "com.-.app")
    }
}
