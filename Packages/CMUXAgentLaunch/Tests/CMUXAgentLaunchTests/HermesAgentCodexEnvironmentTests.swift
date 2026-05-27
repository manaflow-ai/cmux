import CMUXAgentLaunch
import Foundation
import Testing

@Suite("HermesAgentCodexEnvironment")
struct HermesAgentCodexEnvironmentTests {
    @Test("Normalizes Codex ChatGPT base URL for Hermes")
    func normalizesCodexChatGPTBaseURLForHermes() {
        #expect(
            HermesAgentCodexEnvironment.codexBaseURL(
                fromChatGPTBaseURL: "http://subrouter-team:31415/backend-api"
            ) == "http://subrouter-team:31415/backend-api/codex"
        )
        #expect(
            HermesAgentCodexEnvironment.codexBaseURL(
                fromChatGPTBaseURL: "http://subrouter-team:31415/backend-api/codex/"
            ) == "http://subrouter-team:31415/backend-api/codex"
        )
    }

    @Test("Reads top-level Codex ChatGPT base URL")
    func readsTopLevelCodexChatGPTBaseURL() {
        let content = """
        model = "gpt-5.5"
        chatgpt_base_url = "http://subrouter-team:31415/backend-api" # route Codex backend

        [profiles.work]
        chatgpt_base_url = "http://ignored.example/backend-api"
        """

        #expect(
            HermesAgentCodexEnvironment.codexBaseURL(fromCodexConfigContent: content)
                == "http://subrouter-team:31415/backend-api/codex"
        )
    }

    @Test("Applies Codex base URL from CODEX_HOME without overriding explicit Hermes URL")
    func appliesCodexBaseURLFromCodexHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-codex-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        chatgpt_base_url = "http://subrouter-team:31415/backend-api"
        """.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let applied = HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(
            to: ["CODEX_HOME": codexHome.path],
            ambientEnvironment: [:]
        )
        #expect(applied["HERMES_CODEX_BASE_URL"] == "http://subrouter-team:31415/backend-api/codex")

        let explicit = HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(
            to: [
                "CODEX_HOME": codexHome.path,
                "HERMES_CODEX_BASE_URL": "http://custom.example/backend-api/codex",
            ],
            ambientEnvironment: [:]
        )
        #expect(explicit["HERMES_CODEX_BASE_URL"] == "http://custom.example/backend-api/codex")
    }

    @Test("Allows Hermes Codex base URL in captured launch environment")
    func allowsHermesCodexBaseURLInCapturedLaunchEnvironment() {
        #expect(
            AgentLaunchEnvironmentPolicy.selectedEnvironment(
                from: ["HERMES_CODEX_BASE_URL": "http://subrouter-team:31415/backend-api/codex"]
            ) == ["HERMES_CODEX_BASE_URL": "http://subrouter-team:31415/backend-api/codex"]
        )
    }
}
