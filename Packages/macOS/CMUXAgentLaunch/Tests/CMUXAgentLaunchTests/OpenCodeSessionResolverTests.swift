import Testing
@testable import CMUXAgentLaunch

struct OpenCodeSessionResolverTests {
    @Test
    func capturedHomeSelectsHomeLocalShareDatabase() {
        let resolver = OpenCodeSessionResolver(defaultHomeDirectory: "/tmp/fallback-home")

        #expect(
            resolver.capturedDatabasePath(env: ["HOME": "/tmp/custom-home"])
                == "/tmp/custom-home/.local/share/opencode/opencode.db"
        )
    }

    @Test
    func capturedXDGDataHomeTakesPrecedenceAndExpandsAgainstHome() {
        let resolver = OpenCodeSessionResolver(defaultHomeDirectory: "/tmp/fallback-home")

        #expect(
            resolver.capturedDatabasePath(env: [
                "HOME": "/tmp/custom-home",
                "XDG_DATA_HOME": "~/custom-data",
            ]) == "/tmp/custom-home/custom-data/opencode/opencode.db"
        )
    }

    @Test
    func missingCapturedStorageIdentityDoesNotClaimAnExplicitPath() {
        #expect(
            OpenCodeSessionResolver(defaultHomeDirectory: "/tmp/fallback-home")
                .capturedDatabasePath(env: [:]) == nil
        )
    }
}
