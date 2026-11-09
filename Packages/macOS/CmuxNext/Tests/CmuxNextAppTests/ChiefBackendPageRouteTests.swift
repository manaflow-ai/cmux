@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Testing

/// `cmux.chief.backend.add` (u2586): what the page sends becomes the acpmux profile request. An
/// endpoint's key never enters the profile request (only its Keychain item); a command keeps its
/// arguments; a bad form is refused before anything is written.
@Suite struct ChiefBackendPageRouteTests {
    @Test func anEndpointCarriesItsKeyOnlyToTheKeychainStep() throws {
        let backend = try BroughtChiefBackend([
            "kind": "anthropic-endpoint", "name": "Acme Gateway", "baseUrl": "https://api.acme.dev",
            "model": "acme-1", "apiKey": "sk-secret-123",
        ])
        #expect(backend.id == "acme-gateway")
        #expect(backend.kind == .endpoint(example: "anthropic-endpoint", baseURL: "https://api.acme.dev", model: "acme-1", apiKey: "sk-secret-123"))

        var request = AgentHarnessAddRequest()
        request.id = backend.id
        request.displayName = backend.name
        request.example = "anthropic-endpoint"
        request.baseURL = "https://api.acme.dev"
        request.model = "acme-1"
        request.keychainItem = "cmux-harness/acme-gateway/API_KEY"
        let params = request.params
        #expect(params["example"] as? String == "anthropic-endpoint")
        #expect(params["baseUrl"] as? String == "https://api.acme.dev")
        #expect(params["model"] as? String == "acme-1")
        #expect(params["keychainItem"] as? String == "cmux-harness/acme-gateway/API_KEY")
        #expect(!String(describing: params).contains("sk-secret-123"))
    }

    @Test func aCommandKeepsItsArguments() throws {
        let backend = try BroughtChiefBackend(["kind": "command", "name": "My Agent", "command": "my-agent", "args": ["--acp", "--fast"]])
        #expect(backend.kind == .command("my-agent", args: ["--acp", "--fast"]))
    }

    @Test(arguments: [
        ["kind": "openai-endpoint", "name": "X", "baseUrl": "ftp://x", "model": "m", "apiKey": "k"] as JSONValue,
        ["kind": "openai-endpoint", "name": "X", "baseUrl": "https://x.dev", "model": "m", "apiKey": ""],
        ["kind": "command", "name": "X", "command": ""],
        ["kind": "shell", "name": "X", "command": "x"],
        ["kind": "command", "name": " ", "command": "x"],
    ])
    func aBadFormIsRefused(_ params: JSONValue) {
        #expect(throws: PageError.self) { try BroughtChiefBackend(params) }
    }

    /// The page picks the id (a localized name may have no ASCII letters at all) and names the
    /// same id in `replace` only to write its own earlier add again, which may keep the stored key.
    @Test func thePagesIdAndReplaceAreTakenOnlyForTheSameId() throws {
        let fresh = try BroughtChiefBackend([
            "kind": "openai-endpoint", "name": "ローカルモデル", "id": "local-models-2",
            "baseUrl": "http://127.0.0.1:11434/v1", "model": "a,b", "apiKey": "no-key",
        ])
        #expect(fresh.id == "local-models-2")
        #expect(!fresh.replace)
        let again = try BroughtChiefBackend([
            "kind": "openai-endpoint", "name": "ローカルモデル", "id": "local-models-2", "replace": "local-models-2",
            "baseUrl": "http://127.0.0.1:11434/v1", "model": "a",
        ])
        #expect(again.replace)
        #expect(again.kind == .endpoint(example: "openai-endpoint", baseURL: "http://127.0.0.1:11434/v1", model: "a", apiKey: ""))
        // `replace` naming another id replaces nothing, and then a key is required.
        #expect(throws: PageError.self) {
            try BroughtChiefBackend([
                "kind": "openai-endpoint", "name": "X", "id": "mine", "replace": "theirs",
                "baseUrl": "https://x.dev", "model": "m",
            ])
        }
        #expect(try BroughtChiefBackend(["kind": "command", "name": "ローカル", "command": "x"]).id == "my-backend")
    }

    @Test func idsAreLowercaseWordsAndDashes() {
        #expect(BroughtChiefBackend.id(for: "My Backend!") == "my-backend")
        #expect(BroughtChiefBackend.id(for: "--") == "my-backend")
        #expect(BroughtChiefBackend.id(for: "GPT 6 / Astra") == "gpt-6-astra")
        #expect(BroughtChiefBackend.id(for: String(repeating: "ab ", count: 30)).count <= 40)
    }
}
