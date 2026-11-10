@testable import CmuxNextApp
import CmuxNextPages
import CmuxNextSettings
import Testing

/// `cmux.chief.backend.add` (u2586): what the page sends becomes the one acpmux add request. An
/// endpoint's key goes in that add (acpmux stores it in the profile's own Keychain item under the
/// same lock as the id check), only when typed; a command keeps its arguments; a bad form is refused.
@Suite struct ChiefBackendPageRouteTests {
    @Test func anEndpointCarriesItsKeyInTheOneAdd() throws {
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
        request.apiKey = "sk-secret-123"
        let params = request.params
        #expect(params["example"] as? String == "anthropic-endpoint")
        #expect(params["baseUrl"] as? String == "https://api.acme.dev")
        #expect(params["model"] as? String == "acme-1")
        #expect(params["apiKey"] as? String == "sk-secret-123")
        #expect(params["keychainItem"] == nil)
        // A keyless endpoint (a model server on this Mac) sends no key at all.
        request.apiKey = ""
        #expect(request.params["apiKey"] == nil)
    }

    @Test func aCommandKeepsItsArguments() throws {
        let backend = try BroughtChiefBackend(["kind": "command", "name": "My Agent", "command": "my-agent", "args": ["--acp", "--fast"]])
        #expect(backend.kind == .command("my-agent", args: ["--acp", "--fast"]))
    }

    @Test(arguments: [
        ["kind": "openai-endpoint", "name": "X", "baseUrl": "ftp://x", "model": "m", "apiKey": "k"] as JSONValue,
        ["kind": "openai-endpoint", "name": "X", "baseUrl": "https://x.dev", "model": "", "apiKey": "k"],
        ["kind": "command", "name": "X", "command": ""],
        ["kind": "shell", "name": "X", "command": "x"],
        ["kind": "command", "name": " ", "command": "x"],
    ])
    func aBadFormIsRefused(_ params: JSONValue) {
        #expect(throws: PageError.self) { try BroughtChiefBackend(params) }
    }

    /// The page picks the id (a localized name may have no ASCII letters at all) and names the
    /// same id in `replace` only to write its own earlier add again; no key is fine (acpmux keeps
    /// the stored one on `replace`, and a keyless server needs none).
    @Test func thePagesIdAndReplaceAreTakenOnlyForTheSameId() throws {
        let fresh = try BroughtChiefBackend([
            "kind": "openai-endpoint", "name": "ローカルモデル", "id": "local-models-2",
            "baseUrl": "http://127.0.0.1:11434/v1", "model": "a,b",
        ])
        #expect(fresh.id == "local-models-2")
        #expect(!fresh.replace)
        let again = try BroughtChiefBackend([
            "kind": "openai-endpoint", "name": "ローカルモデル", "id": "local-models-2", "replace": "local-models-2",
            "baseUrl": "http://127.0.0.1:11434/v1", "model": "a",
        ])
        #expect(again.replace)
        #expect(again.kind == .endpoint(example: "openai-endpoint", baseURL: "http://127.0.0.1:11434/v1", model: "a", apiKey: ""))
        // `replace` naming another id replaces nothing.
        #expect(try !BroughtChiefBackend([
            "kind": "openai-endpoint", "name": "X", "id": "mine", "replace": "theirs", "baseUrl": "https://x.dev", "model": "m",
        ]).replace)
        #expect(try BroughtChiefBackend(["kind": "command", "name": "ローカル", "command": "x"]).id == "my-backend")
    }

    @Test func idsAreLowercaseWordsAndDashes() {
        #expect(BroughtChiefBackend.id(for: "My Backend!") == "my-backend")
        #expect(BroughtChiefBackend.id(for: "--") == "my-backend")
        #expect(BroughtChiefBackend.id(for: "GPT 6 / Astra") == "gpt-6-astra")
        #expect(BroughtChiefBackend.id(for: String(repeating: "ab ", count: 30)).count <= 40)
    }
}
