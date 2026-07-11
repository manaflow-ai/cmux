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

    @Test("Reads legacy hook state after moving writers into a bundle scope")
    func resolvesBundleScopedReadFallback() {
        let applicationSupport = URL(fileURLWithPath: "/tmp/app-support", isDirectory: true)
        let home = URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        let scoped = applicationSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("agent-hooks", isDirectory: true)
            .appendingPathComponent("com.cmuxterm.app.nightly", isDirectory: true)

        let directories = AgentHookStateLocation.resolveReadDirectoryURLs(
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": scoped.path],
            applicationSupportDirectory: applicationSupport,
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: home
        )

        #expect(directories == [
            scoped,
            home.appendingPathComponent(".cmuxterm", isDirectory: true),
        ])
    }

    @Test("Keeps an unrelated explicit hook state override isolated")
    func explicitReadOverrideDoesNotUseLegacyFallback() {
        let override = URL(fileURLWithPath: "/tmp/custom-hook-state", isDirectory: true)

        let directories = AgentHookStateLocation.resolveReadDirectoryURLs(
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": override.path],
            applicationSupportDirectory: URL(fileURLWithPath: "/tmp/app-support", isDirectory: true),
            bundleIdentifier: "com.cmuxterm.app.nightly",
            legacyHomeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        )

        #expect(directories == [override])
    }
}
