import Foundation
import Testing
@testable import CmuxNextCodeRouter

@Suite struct ProviderDetectorTests {
    @Test func emptyHomeFindsNothing() async throws {
        let home = try FixtureHome()
        let results = await ProviderDetector(environment: home.environment()).detectAll()
        #expect(results.map(\.provider) == AIProvider.allCases)
        #expect(results.allSatisfy { $0.status == .missing })
    }

    @Test func codexChatGPTSignInShowsLabelAndPlanOnly() async throws {
        let home = try FixtureHome()
        try home.writeJSON(".codex/auth.json", codexAuth())
        let result = ProviderDetector(environment: home.environment()).detectCodex()
        #expect(result.status == .signedIn)
        #expect(result.account == fixtureLabeler.local(.codex, identity: "dev@example.com", plan: "pro"))
        #expect(result.account?.display == "pro")
        #expect(result.plan == "pro")
        #expect(result.sources == [.file("~/.codex/auth.json")])
        // No secret may appear anywhere in the result.
        #expect(!String(describing: result).contains("fake-refresh-token"))
        #expect(!String(describing: result).contains("acct-fixture"))
    }

    @Test func codexHomeFromEnvironment() throws {
        let home = try FixtureHome()
        try home.writeJSON("alt-codex/auth.json", codexAuth(email: "alt@example.com"))
        let env = home.environment(["CODEX_HOME": home.url.appendingPathComponent("alt-codex").path])
        let account = try #require(ProviderDetector(environment: env).detectCodex().account)
        #expect(account.handle == fixtureLabeler.handle(namespace: "codex", identity: "alt@example.com"))
    }

    @Test func codexWithoutRefreshTokenAndExpiredAccessIsExpired() throws {
        let home = try FixtureHome()
        try home.writeJSON(".codex/auth.json", codexAuth(refresh: "", accessExpiry: 1_000))
        #expect(ProviderDetector(environment: home.environment()).detectCodex().status == .expired)
    }

    @Test func codexAPIKeyModeAndBrokenFile() throws {
        let home = try FixtureHome()
        try home.writeJSON(".codex/auth.json", ["OPENAI_API_KEY": "sk-fixture-not-a-real-key"])
        let apiKey = ProviderDetector(environment: home.environment()).detectCodex()
        #expect(apiKey.status == .signedIn)
        #expect(apiKey.account == nil)
        try home.write(".codex/auth.json", "{ not json")
        #expect(ProviderDetector(environment: home.environment()).detectCodex().status == .unknown)
    }

    @Test func codexKeyringStoreChecksKeychainPresence() throws {
        let home = try FixtureHome()
        try home.write(".codex/config.toml", "model = \"gpt-5\"\ncli_auth_credentials_store = \"keyring\"\n")
        #expect(ProviderDetector(environment: home.environment()).detectCodex().status == .missing)
        let found = ProviderDetector(environment: home.environment(keychain: ["Codex Auth"])).detectCodex()
        #expect(found.status == .signedIn)
        #expect(found.sources == [.keychain("Codex Auth")])
    }

    @Test func claudeKeychainItemWithIdentityFromClaudeJSON() throws {
        let home = try FixtureHome()
        try home.writeJSON(".claude.json", ["oauthAccount": ["emailAddress": "claude@example.com", "organizationName": "Acme"]])
        let none = ProviderDetector(environment: home.environment()).detectClaudeCode()
        #expect(none.status == .missing)
        let result = ProviderDetector(environment: home.environment(keychain: ["Claude Code-credentials"])).detectClaudeCode()
        #expect(result.status == .signedIn)
        #expect(result.account?.handle == fixtureLabeler.handle(namespace: "claude", identity: "claude@example.com"))
        #expect(result.account?.display == "Acme")
        #expect(result.plan == "Acme")
        #expect(result.sources == [.keychain("Claude Code-credentials")])
    }

    @Test func claudeCredentialsFileExpiry() throws {
        let home = try FixtureHome()
        try home.writeJSON(".claude/.credentials.json", ["claudeAiOauth": ["accessToken": "fake", "refreshToken": "", "expiresAt": 1_000]])
        #expect(ProviderDetector(environment: home.environment()).detectClaudeCode().status == .expired)
        try home.writeJSON(".claude/.credentials.json", ["claudeAiOauth": ["accessToken": "fake", "refreshToken": "fake-r", "expiresAt": 1_000]])
        #expect(ProviderDetector(environment: home.environment()).detectClaudeCode().status == .signedIn)
    }

    @Test func claudeOAuthTokenEnvironment() throws {
        let home = try FixtureHome()
        let result = ProviderDetector(environment: home.environment(["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-fixture"])).detectClaudeCode()
        #expect(result.status == .signedIn)
        #expect(result.sources == [.environment("CLAUDE_CODE_OAUTH_TOKEN")])
    }

    @Test func apiKeysFromEnvironmentAndCmuxKeychain() throws {
        let home = try FixtureHome()
        let env = home.environment(["ANTHROPIC_API_KEY": "sk-ant-fixture", "OPENAI_API_KEY": "  ", "GOOGLE_API_KEY": "fixture"],
                                   savedKeys: [.groq])
        let detector = ProviderDetector(environment: env)
        #expect(detector.detectLocal(.anthropic).sources == [.environment("ANTHROPIC_API_KEY")])
        #expect(detector.detectLocal(.openAI).status == .missing, "a blank value is not a key")
        #expect(detector.detectLocal(.gemini).sources == [.environment("GOOGLE_API_KEY")])
        #expect(detector.detectLocal(.groq).sources == [.cmuxKeychain])
        #expect(detector.detectLocal(.xai).status == .missing)
    }

    @Test func geminiGoogleSignIn() throws {
        let home = try FixtureHome()
        try home.writeJSON(".gemini/oauth_creds.json", ["refresh_token": "fake"])
        try home.writeJSON(".gemini/google_accounts.json", ["active": "g@example.com", "old": []])
        let result = ProviderDetector(environment: home.environment()).detectGemini()
        #expect(result.status == .signedIn)
        #expect(result.account?.handle == fixtureLabeler.handle(namespace: "gemini", identity: "g@example.com"))
        #expect(result.account?.display == "g…@e…")
    }

    @Test func bedrockProfilesNamesOnly() throws {
        let home = try FixtureHome()
        try home.write(".aws/credentials", "[default]\naws_access_key_id = FIXTURE\naws_secret_access_key = FIXTURE\n")
        try home.write(".aws/config", "[profile work]\nregion = us-west-2\n[sso-session corp]\nsso_region = us-east-1\n")
        let result = ProviderDetector(environment: home.environment(["AWS_PROFILE": "work"])).detectBedrock()
        #expect(result.status == .signedIn)
        #expect(result.detail == "profile work")
        #expect(result.account == nil)
        #expect(!String(describing: result).contains("FIXTURE"))
        #expect(ProviderDetector.iniProfiles("[sso-session x]\n[profile a]\n[b]") == ["a", "b"])
    }

    @Test func vertexADCTypeAndServiceAccountEmail() throws {
        let home = try FixtureHome()
        try home.writeJSON(".config/gcloud/application_default_credentials.json", ["type": "authorized_user", "refresh_token": "fake"])
        #expect(ProviderDetector(environment: home.environment()).detectVertex().detail == "authorized_user")
        try home.writeJSON("sa.json", ["type": "service_account", "client_email": "bot@proj.iam.gserviceaccount.com", "private_key": "fake"])
        let env = home.environment(["GOOGLE_APPLICATION_CREDENTIALS": home.url.appendingPathComponent("sa.json").path])
        let result = ProviderDetector(environment: env).detectVertex()
        #expect(result.account?.handle == fixtureLabeler.handle(namespace: "vertex", identity: "bot@proj.iam.gserviceaccount.com"))
        #expect(result.account?.display == "b…@p…")
        #expect(result.detail == nil)
        #expect(!String(describing: result).contains("private_key"))
    }

    @Test func copilotUserLogin() throws {
        let home = try FixtureHome()
        try home.writeJSON(".config/github-copilot/apps.json", ["github.com:Iv1.fixture": ["user": "octocat", "oauth_token": "fake"]])
        let result = ProviderDetector(environment: home.environment()).detectCopilot()
        #expect(result.status == .signedIn)
        #expect(result.account?.handle == fixtureLabeler.handle(namespace: "copilot", identity: "octocat"))
        #expect(result.account?.display == "o…", "a GitHub login is personal data: shortened")
    }

    @Test func localServersByReachability() async throws {
        let home = try FixtureHome()
        let env = home.environment(["OLLAMA_HOST": "0.0.0.0:11500"], servers: ["http://127.0.0.1:11500/api/tags"])
        let results = await ProviderDetector(environment: env).detectAll()
        let ollama = try #require(results.first { $0.provider == .ollama })
        #expect(ollama.status == .signedIn)
        #expect(ollama.detail == "127.0.0.1:11500")
        #expect(results.first { $0.provider == .lmStudio }?.status == .missing)
    }
}
