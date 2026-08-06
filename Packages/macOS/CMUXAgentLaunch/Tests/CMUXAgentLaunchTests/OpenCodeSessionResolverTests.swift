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
    func capturedEffectiveDatabasePathTakesPrecedenceOverDefaultStorage() {
        let resolver = OpenCodeSessionResolver(defaultHomeDirectory: "/tmp/fallback-home")

        #expect(
            resolver.capturedDatabasePath(env: [
                "HOME": "/tmp/custom-home",
                "CMUX_OPENCODE_DATABASE_PATH": "/tmp/custom-home/.local/share/opencode/opencode-dev.db",
            ]) == "/tmp/custom-home/.local/share/opencode/opencode-dev.db"
        )
    }

    @Test
    func tildeCapturedDatabasePathIsNotTreatedAsKernelProvenance() {
        let resolver = OpenCodeSessionResolver(defaultHomeDirectory: "/tmp/fallback-home")

        #expect(
            resolver.capturedDatabasePath(env: [
                "HOME": "/tmp/custom-home",
                "CMUX_OPENCODE_DATABASE_PATH": "~/spoofed.db",
            ]) == "/tmp/custom-home/.local/share/opencode/opencode.db"
        )
    }

    @Test
    func explicitRelativeDatabaseUsesOpenCodeDataDirectory() {
        let resolver = OpenCodeSessionResolver(defaultHomeDirectory: "/tmp/fallback-home")

        #expect(
            resolver.capturedDatabasePath(env: [
                "HOME": "/tmp/custom-home",
                "OPENCODE_DB": "custom.db",
            ]) == "/tmp/custom-home/.local/share/opencode/custom.db"
        )
    }

    @Test
    func relativeDatabaseWithoutCapturedRootsIsNotTransferable() {
        let resolver = OpenCodeSessionResolver(defaultHomeDirectory: "/tmp/current-cmux-home")

        #expect(
            resolver.capturedDatabasePath(env: [
                "OPENCODE_DB": "custom.db",
            ]) == nil
        )
    }

    @Test
    func tildeDataHomeWithoutCapturedHomeIsNotTransferable() {
        let resolver = OpenCodeSessionResolver(defaultHomeDirectory: "/tmp/current-cmux-home")

        #expect(
            resolver.capturedDatabasePath(env: [
                "XDG_DATA_HOME": "~/custom-data",
            ]) == nil
        )
    }

    @Test
    func relativeXDGDataHomeIsNotTransferable() {
        let resolver = OpenCodeSessionResolver(defaultHomeDirectory: "/tmp/fallback-home")

        #expect(
            resolver.capturedDatabasePath(env: [
                "HOME": "/tmp/custom-home",
                "XDG_DATA_HOME": "relative-data",
                "OPENCODE_DB": "custom.db",
            ]) == nil
        )
    }

    @Test
    func inMemoryDatabaseIsNotTransferable() {
        #expect(
            OpenCodeSessionResolver(defaultHomeDirectory: "/tmp/fallback-home")
                .capturedDatabasePath(env: [
                    "HOME": "/tmp/custom-home",
                    "OPENCODE_DB": ":memory:",
                ]) == nil
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
