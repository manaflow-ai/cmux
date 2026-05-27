import CMUXAgentLaunch
import Foundation
import Testing

@Suite("AgentLaunchEnvironmentPolicy")
struct AgentLaunchEnvironmentPolicyTests {
    @Test("Normalizes Pi Subrouter config directory aliases")
    func normalizesPiSubrouterConfigDirectoryAliases() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-subrouter-home-\(UUID().uuidString)", isDirectory: true)
        let legacyConfig = home
            .appendingPathComponent(".subrouter", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("pi", isDirectory: true)
            .appendingPathComponent("_p1775010019397", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyConfig, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".codex-accounts", isDirectory: true),
            withDestinationURL: home.appendingPathComponent(".subrouter", isDirectory: true)
                .appendingPathComponent("codex", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let selected = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: [
            "PI_CODING_AGENT_DIR": legacyConfig.path,
            "OPENAI_API_KEY": "secret",
        ], homeDirectory: home.path)

        #expect(
            selected["PI_CODING_AGENT_DIR"] == home
                .appendingPathComponent(".codex-accounts", isDirectory: true)
                .appendingPathComponent("pi", isDirectory: true)
                .appendingPathComponent("_p1775010019397", isDirectory: true)
                .path
        )
        #expect(selected["OPENAI_API_KEY"] == nil)
    }

    @Test("Keeps legacy Pi Subrouter path when no alias exists")
    func keepsLegacyPiSubrouterPathWithoutAlias() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-subrouter-legacy-home-\(UUID().uuidString)", isDirectory: true)
        let legacyConfig = home
            .appendingPathComponent(".subrouter", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("pi", isDirectory: true)
            .appendingPathComponent("_p1775010019397", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyConfig, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(
            PiConfigDirectoryPath.preferredPath(legacyConfig.path, homeDirectory: home.path) == legacyConfig.path
        )
    }
}
