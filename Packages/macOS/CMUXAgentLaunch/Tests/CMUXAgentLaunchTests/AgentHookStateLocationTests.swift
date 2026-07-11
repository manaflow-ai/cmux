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
}
