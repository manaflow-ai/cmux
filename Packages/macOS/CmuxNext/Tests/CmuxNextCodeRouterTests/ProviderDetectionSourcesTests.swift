@testable import CmuxNextCodeRouter
import Foundation
import Testing

/// Settings > Accounts finds every provider path the CLI itself would use
/// (hq#2569 #2): on the sr-configured minis it said "Not found" for Codex and
/// Claude Code while both CLIs worked. One case per detection source.
struct ProviderDetectionSourcesTests {
    static let home = URL(fileURLWithPath: "/fixture/home", isDirectory: true)

    struct Files: FileReading {
        let files: [String: String]
        func data(at url: URL) -> Data? { files[url.standardizedFileURL.path].map { Data($0.utf8) } }
        func exists(_ url: URL) -> Bool { files[url.standardizedFileURL.path] != nil }
    }

    struct Keychain: KeychainProbing {
        let services: Set<String>
        var values: [String: Data] = [:]
        func hasGenericPassword(service: String) -> Bool { services.contains(service) }
        func genericPassword(service: String) -> Data? { values[service] }
    }

    struct NoServers: LocalServerProbing {
        func isReachable(_ url: URL) async -> Bool { false }
    }

    struct EmptyKeys: ProviderKeyStoring {
        func savedProviders() -> Set<AIProvider> { [] }
        func save(_ key: String, for provider: AIProvider) throws {}
        func key(for provider: AIProvider) throws -> String? { nil }
        func delete(for provider: AIProvider) throws {}
    }

    static func detector(files: [String: String] = [:], env: [String: String] = [:], keychain: Set<String> = []) -> ProviderDetector {
        ProviderDetector(environment: DetectionEnvironment(
            home: home, environment: env, files: Files(files: files), keychain: Keychain(services: keychain),
            servers: NoServers(), labeler: AccountLabeler(salt: Data(repeating: 7, count: 32))))
    }

    static let codexConfig = "/fixture/home/.codex/config.toml"
    static let srConfig = """
        model_provider = "subrouter"
        openai_base_url = "http://127.0.0.1:31415/v1"

        [model_providers.subrouter]
        name = "Subrouter"
        base_url = "http://127.0.0.1:31415/v1"
        experimental_bearer_token = "sr-secret"
        wire_api = "responses"

        [projects."/Users/cmux/Projects/a.b"]
        trust_level = "trusted"
        """

    // MARK: Codex

    @Test func codexWithNothingIsMissing() {
        #expect(Self.detector().detectCodex().status == .missing)
    }

    @Test func codexThroughABearerTokenProviderIsSignedInButNotLinkable() {
        let detection = Self.detector(files: [Self.codexConfig: Self.srConfig]).detectCodex()
        #expect(detection.status == .signedIn)
        #expect(detection.detail == "Subrouter")
        #expect(detection.sources == [.providerConfig("~/.codex/config.toml")])
        var row = AccountRowState(provider: .codex)
        row.reduce(.cmuxSignIn(true))
        row.reduce(.detected(detection))
        #expect(row.usesProviderConfig)
        #expect(!row.canConnect)
    }

    @Test func codexHomeComesFromTheEnvironment() {
        let files = ["/srv/codex/config.toml": Self.srConfig]
        #expect(Self.detector(files: files).detectCodex().status == .missing)
        #expect(Self.detector(files: files, env: ["CODEX_HOME": "/srv/codex"]).detectCodex().status == .signedIn)
    }

    @Test func codexEnvKeyCountsOnlyWhenSet() {
        let config = """
            model_provider = "router"
            [model_providers.router]
            base_url = "https://router.example/v1"
            env_key = "ROUTER_KEY" # the router's key
            """
        let unset = Self.detector(files: [Self.codexConfig: config]).detectCodex()
        #expect(unset.status == .unknown)
        let set = Self.detector(files: [Self.codexConfig: config], env: ["ROUTER_KEY": "k"]).detectCodex()
        #expect(set.status == .signedIn)
        #expect(set.sources == [.providerConfig("~/.codex/config.toml"), .environment("ROUTER_KEY")])
    }

    @Test func codexProfileSelectsTheProvider() {
        let config = """
            profile = "sr"
            [profiles.sr]
            model_provider = "subrouter"
            [model_providers.subrouter]
            experimental_bearer_token = "t"
            """
        #expect(Self.detector(files: [Self.codexConfig: config]).detectCodex().status == .signedIn)
    }

    @Test func codexKeyringCredentialCanConnect() throws {
        let idToken = "eyJhbGciOiJub25lIn0.eyJlbWFpbCI6ImZvdW5kZXJAZXhhbXBsZS5jb20ifQ."
        let auth = Data("{\"tokens\":{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"id_token\":\"\(idToken)\",\"account_id\":\"acct\"}}".utf8)
        let files = Files(files: ["/fixture/home/.codex/config.toml": "cli_auth_credentials_store = \"keyring\""])
        let keychain = Keychain(services: [ProviderDetector.codexKeychainService], values: [ProviderDetector.codexKeychainService: auth])
        let environment = DetectionEnvironment(home: Self.home, environment: [:], files: files, keychain: keychain,
                                                servers: NoServers(), labeler: AccountLabeler(salt: Data(repeating: 7, count: 32)))
        let credential = try CredentialResolver(environment: environment, keys: EmptyKeys()).codexCredential()
        #expect(credential.accountID == "acct")
        #expect(credential.email == "founder@example.com")
    }

    @Test(arguments: [
        "model = \"gpt-5\"",
        "model_provider = \"openai\"",
        "model_provider = \"azure\"\n[model_providers.azure]\nrequires_openai_auth = true\nexperimental_bearer_token = \"t\"",
    ])
    func codexOpenAIProvidersNeedTheSignIn(config: String) {
        #expect(Self.detector(files: [Self.codexConfig: config]).detectCodex().status == .missing)
    }

    @Test func codexLocalAndAuthCommandProvidersAreSignedIn() {
        for config in ["model_provider = \"ollama\"",
                       "model_provider = \"c\"\n[model_providers.c]\nbase_url = \"https://c/v1\"\n[model_providers.c.auth]\ncommand = \"print-token\""] {
            #expect(Self.detector(files: [Self.codexConfig: config]).detectCodex().status == .signedIn, "\(config)")
        }
    }

    @Test func codexChatGPTSignInStaysLinkableNextToAProvider() {
        let auth = "{\"tokens\": {\"refresh_token\": \"r\", \"access_token\": \"a\"}}"
        let detection = Self.detector(files: [Self.codexConfig: Self.srConfig, "/fixture/home/.codex/auth.json": auth]).detectCodex()
        #expect(detection.status == .signedIn)
        #expect(detection.sources == [.file("~/.codex/auth.json")])
        var row = AccountRowState(provider: .codex)
        row.reduce(.cmuxSignIn(true))
        row.reduce(.detected(detection))
        #expect(row.canConnect)
    }

    @Test(arguments: [
        "model_provider = \"router\"\nmodel_providers = { router = { name = \"Router\", experimental_bearer_token = \"t\" } }",
        "model_provider = \"router\"\n[model_providers]\nrouter = { name = \"Router\", experimental_bearer_token = \"t\" }",
        "model_provider = \"router\"\n[model_providers]\nrouter.name = \"Router\"\nrouter.auth = { command = \"print-token\", args = [\"a,}\"] }",
    ])
    func codexInlineProviderTablesAreRead(config: String) {
        let detection = Self.detector(files: [Self.codexConfig: config]).detectCodex()
        #expect(detection.status == .signedIn)
        #expect(detection.detail == "Router")
    }

    @Test func miniTOMLReadsInlineTables() {
        let toml = MiniTOML("""
            t = { a = "x, }", b.c = true, d = { e = 'y' }, list = [1, { f = "no" }], n = 3 } # done
            after = "z"
            """)
        #expect(toml.string(["t", "a"]) == "x, }")
        #expect(toml.bool(["t", "b", "c"]) == true)
        #expect(toml.string(["t", "d", "e"]) == "y")
        #expect(toml.hasTable(["t"]))
        #expect(toml.hasTable(["t", "b"]))
        #expect(toml.hasTable(["t", "d"]))
        #expect(toml.has(["t", "list"]))
        #expect(toml.string(["f"]) == nil)
        #expect(toml.has(["t", "n"]))
        #expect(toml.string(["after"]) == "z")
    }

    @Test func miniTOMLReadsQuotedDottedKeysAndSkipsArrays() {
        let toml = MiniTOML("""
            a.b = "x"
            [t."q.r"]
            flag = true
            list = [
              "k = v",
            ]
            [[arr]]
            model_provider = "nope"
            """)
        #expect(toml.string(["a", "b"]) == "x")
        #expect(toml.bool(["t", "q.r", "flag"]) == true)
        #expect(toml.hasTable(["t", "q.r"]))
        #expect(toml.string(["model_provider"]) == nil)
    }

    // MARK: Claude Code

    @Test func claudeWithNothingIsMissing() {
        #expect(Self.detector().detectClaudeCode().status == .missing)
    }

    @Test func claudeOAuthTokenInTheEnvironment() {
        let detection = Self.detector(env: ["CLAUDE_CODE_OAUTH_TOKEN": "t"]).detectClaudeCode()
        #expect(detection.status == .signedIn)
        #expect(detection.sources == [.environment("CLAUDE_CODE_OAUTH_TOKEN")])
    }

    @Test func claudeGatewayTokenInSettingsEnv() {
        let settings = "{\"env\": {\"ANTHROPIC_BASE_URL\": \"http://127.0.0.1:31415\", \"ANTHROPIC_AUTH_TOKEN\": \"t\"}}"
        let detection = Self.detector(files: ["/fixture/home/.claude/settings.json": settings]).detectClaudeCode()
        #expect(detection.status == .signedIn)
        #expect(detection.detail == "ANTHROPIC_AUTH_TOKEN")
        #expect(detection.sources == [.file("~/.claude/settings.json")])
    }

    @Test func claudeConfigDirComesFromTheEnvironment() {
        let files = ["/srv/claude/settings.json": "{\"apiKeyHelper\": \"/bin/key\"}"]
        #expect(Self.detector(files: files).detectClaudeCode().status == .missing)
        let detection = Self.detector(files: files, env: ["CLAUDE_CONFIG_DIR": "/srv/claude"]).detectClaudeCode()
        #expect(detection.status == .signedIn)
        #expect(detection.detail == "apiKeyHelper")
    }

    @Test(arguments: ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"])
    func claudeKeyInTheEnvironment(key: String) {
        let detection = Self.detector(env: [key: "k"]).detectClaudeCode()
        #expect(detection.status == .signedIn)
        #expect(detection.sources == [.environment(key)])
    }

    @Test func claudeCloudSwitchIsOnlyOnWhenTruthy() {
        #expect(Self.detector(env: ["CLAUDE_CODE_USE_BEDROCK": "1"]).detectClaudeCode().status == .signedIn)
        #expect(Self.detector(env: ["CLAUDE_CODE_USE_BEDROCK": "0"]).detectClaudeCode().status == .missing)
        let settings = "{\"env\": {\"CLAUDE_CODE_USE_VERTEX\": true}}"
        #expect(Self.detector(files: ["/fixture/home/.claude/settings.json": settings]).detectClaudeCode().status == .signedIn)
    }

    @Test func claudeSavedAPIKey() {
        let detection = Self.detector(files: ["/fixture/home/.claude.json": "{\"primaryApiKey\": \"k\"}"]).detectClaudeCode()
        #expect(detection.status == .signedIn)
        #expect(detection.sources == [.file("~/.claude.json")])
        // Accounts words the credential type in the user's language.
        #expect(detection.note == .savedAPIKey)
        #expect(detection.detail == nil)
    }

    @Test(arguments: [
        "{}",
        "{\"claudeAiOauth\": {\"accessToken\": \"a\", \"expiresAt\": 1000}}",
    ])
    func claudeGatewayTokenWinsOverAnUnusableCredentialsFile(credentials: String) {
        let settings = "{\"env\": {\"ANTHROPIC_AUTH_TOKEN\": \"t\"}}"
        let detection = Self.detector(files: ["/fixture/home/.claude/.credentials.json": credentials,
                                              "/fixture/home/.claude/settings.json": settings]).detectClaudeCode()
        #expect(detection.status == .signedIn)
        #expect(detection.detail == "ANTHROPIC_AUTH_TOKEN")
        #expect(detection.sources == [.file("~/.claude/settings.json")])
    }

    @Test func claudeUnusableCredentialsFileStaysWhenNothingElseIsConfigured() {
        let expired = "{\"claudeAiOauth\": {\"accessToken\": \"a\", \"expiresAt\": 1000}}"
        let detection = Self.detector(files: ["/fixture/home/.claude/.credentials.json": expired]).detectClaudeCode()
        #expect(detection.status == .expired)
        #expect(detection.sources == [.file("~/.claude/.credentials.json")])
    }

    @Test func claudeUsableCredentialsFileComesFirst() {
        let credentials = "{\"claudeAiOauth\": {\"accessToken\": \"a\", \"refreshToken\": \"r\"}}"
        let settings = "{\"env\": {\"ANTHROPIC_AUTH_TOKEN\": \"t\"}}"
        let detection = Self.detector(files: ["/fixture/home/.claude/.credentials.json": credentials,
                                              "/fixture/home/.claude/settings.json": settings]).detectClaudeCode()
        #expect(detection.status == .signedIn)
        #expect(detection.sources == [.file("~/.claude/.credentials.json")])
    }

    @Test func claudeKeychainSignInComesFirst() {
        let settings = "{\"env\": {\"ANTHROPIC_AUTH_TOKEN\": \"t\"}}"
        let detection = Self.detector(files: ["/fixture/home/.claude/settings.json": settings],
                                      keychain: [ProviderDetector.claudeKeychainService]).detectClaudeCode()
        #expect(detection.sources == [.keychain(ProviderDetector.claudeKeychainService)])
    }
}
