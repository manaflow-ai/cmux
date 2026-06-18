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
        #expect(
            HermesAgentCodexEnvironment.customBaseURL(
                fromChatGPTBaseURL: "http://subrouter-team:31415/backend-api"
            ) == "http://subrouter-team:31415/v1"
        )
        #expect(
            HermesAgentCodexEnvironment.customBaseURL(
                fromOpenAIBaseURL: "http://subrouter-team:31415/v1/"
            ) == "http://subrouter-team:31415/v1"
        )
        #expect(
            HermesAgentCodexEnvironment.customBaseURL(
                fromOpenAIBaseURL: "https://api.openai.com/v1"
            ) == nil
        )
        #expect(
            HermesAgentCodexEnvironment.customBaseURL(
                fromChatGPTBaseURL: "https://chatgpt.com/backend-api"
            ) == nil
        )
        #expect(HermesAgentCodexEnvironment.codexBaseURL(fromChatGPTBaseURL: "https://") == nil)
        #expect(HermesAgentCodexEnvironment.codexBaseURL(fromChatGPTBaseURL: "https://host?x=1") == nil)
        #expect(HermesAgentCodexEnvironment.customBaseURL(fromOpenAIBaseURL: "https://") == nil)
        #expect(HermesAgentCodexEnvironment.customBaseURL(fromOpenAIBaseURL: "https://host?x=1") == nil)
        #expect(HermesAgentCodexEnvironment.customBaseURL(fromChatGPTBaseURL: "https://") == nil)
        #expect(HermesAgentCodexEnvironment.customBaseURL(fromChatGPTBaseURL: "https://host?x=1") == nil)
    }

    @Test("Reads top-level Codex base URLs")
    func readsTopLevelCodexBaseURLs() {
        let content = """
        model = "gpt-5.5"
        openai_base_url = "http://subrouter-team:31415/v1"
        chatgpt_base_url = "http://subrouter-team:31415/backend-api" # route Codex backend

        [profiles.work]
        openai_base_url = "http://ignored.example/v1"
        chatgpt_base_url = "http://ignored.example/backend-api"
        """

        #expect(
            HermesAgentCodexEnvironment.codexBaseURL(fromCodexConfigContent: content)
                == "http://subrouter-team:31415/backend-api/codex"
        )
        #expect(
            HermesAgentCodexEnvironment.customBaseURL(fromCodexConfigContent: content)
                == "http://subrouter-team:31415/v1"
        )
        #expect(
            HermesAgentCodexEnvironment.codexModel(fromCodexConfigContent: content)
                == "gpt-5.5"
        )
    }

    @Test("Applies Codex base URL from CODEX_HOME without overriding explicit Hermes URL")
    func appliesCodexBaseURLFromCodexHome() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-codex-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        openai_base_url = "http://subrouter-team:31415/v1"
        chatgpt_base_url = "http://subrouter-team:31415/backend-api"
        """.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let applied = HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(
            to: ["CODEX_HOME": codexHome.path],
            ambientEnvironment: [:]
        )
        #expect(applied["HERMES_CODEX_BASE_URL"] == "http://subrouter-team:31415/backend-api/codex")
        #expect(applied["CUSTOM_BASE_URL"] == "http://subrouter-team:31415/v1")

        let explicit = HermesAgentCodexEnvironment.applyingDefaultCodexBaseURL(
            to: [
                "CODEX_HOME": codexHome.path,
                "CUSTOM_BASE_URL": "http://custom.example/v1",
                "HERMES_CODEX_BASE_URL": "http://custom.example/backend-api/codex",
            ],
            ambientEnvironment: [:]
        )
        #expect(explicit["HERMES_CODEX_BASE_URL"] == "http://custom.example/backend-api/codex")
        #expect(explicit["CUSTOM_BASE_URL"] == "http://custom.example/v1")
    }

    @Test("Allows Hermes Codex subrouter URLs in captured launch environment")
    func allowsHermesCodexSubrouterURLsInCapturedLaunchEnvironment() {
        #expect(
            AgentLaunchEnvironmentPolicy.selectedEnvironment(
                from: [
                    "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
                    "HERMES_CODEX_BASE_URL": "http://subrouter-team:31415/backend-api/codex",
                ],
                kind: "hermes-agent"
            ) == [
                "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
                "HERMES_CODEX_BASE_URL": "http://subrouter-team:31415/backend-api/codex",
            ]
        )
        #expect(
            AgentLaunchEnvironmentPolicy.selectedEnvironment(
                from: [
                    "CUSTOM_BASE_URL": "http://subrouter-team:31415/v1",
                    "HERMES_CODEX_BASE_URL": "http://subrouter-team:31415/backend-api/codex",
                ],
                kind: "codex"
            ).isEmpty
        )
    }
}
