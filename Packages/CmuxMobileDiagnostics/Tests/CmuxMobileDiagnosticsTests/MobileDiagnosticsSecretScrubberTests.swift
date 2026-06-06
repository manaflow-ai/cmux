import Foundation
import Testing
@testable import CmuxMobileDiagnostics

@Suite struct MobileDiagnosticsSecretScrubberTests {
    private let scrubber = MobileDiagnosticsSecretScrubber()

    @Test func redactsBearerToken() {
        let out = scrubber.scrub("Authorization: Bearer abcDEF123.ghi_jkl-mno")
        #expect(out == "Authorization: Bearer <redacted>")
    }

    @Test func redactsJwtLikeTriple() {
        let jwt = "eyJhbGciOi.eyJzdWIiOiI.SflKxwRJSM"
        let out = scrubber.scrub("token is \(jwt) here")
        #expect(!out.contains(jwt))
        #expect(out.contains("<redacted>"))
    }

    @Test func redactsKeyValueSecrets() {
        #expect(scrubber.scrub("password=hunter2longvalue").contains("<redacted>"))
        #expect(!scrubber.scrub("password=hunter2longvalue").contains("hunter2longvalue"))
        #expect(scrubber.scrub("token=abcd1234efgh").contains("<redacted>"))
        #expect(scrubber.scrub("api_key: \"sekret-value-here\"").contains("<redacted>"))
    }

    @Test func redactsFirstQueryStringSecrets() {
        let accessTokenURL = "https://example.com/callback?access_token=abcd1234efgh&ok=1"
        let apiKeyURL = "https://example.com/search?api_key=sekretvalue123&q=cmux"

        let scrubbedAccessTokenURL = scrubber.scrub(accessTokenURL)
        let scrubbedAPIKeyURL = scrubber.scrub(apiKeyURL)

        #expect(scrubbedAccessTokenURL.contains("access_token=<redacted>"))
        #expect(scrubbedAPIKeyURL.contains("api_key=<redacted>"))
        #expect(!scrubbedAccessTokenURL.contains("abcd1234efgh"))
        #expect(!scrubbedAPIKeyURL.contains("sekretvalue123"))
    }

    @Test func redactsProviderPrefixedKeys() {
        #expect(scrubber.scrub("sk-abcdefghij0123456789xyz").contains("<redacted>"))
        #expect(scrubber.scrub("ghp_abcdefghij0123456789abcdef").contains("<redacted>"))
    }

    @Test func redactsUpperSnakeEnvVarSecrets() {
        for sample in [
            "API_TOKEN=plainopaquevalue123",
            "GITHUB_TOKEN=abcd1234efgh",
            "DB_PASSWORD=plainvalue123",
            "STACK_REFRESH_TOKEN=opaquevalue9999",
            "AWS_SECRET=plainsecret456",
        ] {
            let out = scrubber.scrub(sample)
            #expect(out.contains("<redacted>"), "expected redaction for \(sample), got \(out)")
            #expect(!out.contains("plain"), "value leaked for \(sample): \(out)")
            #expect(!out.contains("abcd1234efgh"))
            #expect(!out.contains("opaquevalue9999"))
        }
    }

    @Test func redactsCanonicalAWSCredentialEnvironmentVariables() {
        let samples = [
            ("AWS_ACCESS_KEY_ID=AKIAIOSDIAGNOSTICS123", "AKIAIOSDIAGNOSTICS123"),
            ("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "wJalrXUtnFEMI"),
            ("AWS_SESSION_TOKEN=IQoJb3JpZ2luX2VjEFAaCXVzLXdlc3QtMiJHMEUCIQD", "IQoJb3JpZ2lu"),
            ("AWS_SECURITY_TOKEN=legacySecurityTokenValue123", "legacySecurityTokenValue123"),
        ]

        for (sample, leakedFragment) in samples {
            let out = scrubber.scrub(sample)
            #expect(out.contains("<redacted>"), "expected redaction for \(sample), got \(out)")
            #expect(out.contains(sample.split(separator: "=")[0]))
            #expect(!out.contains(leakedFragment), "value leaked for \(sample): \(out)")
        }
    }

    @Test func doesNotRedactKeywordSubstrings() {
        #expect(scrubber.scrub("tokenizer=gpt2") == "tokenizer=gpt2")
        #expect(scrubber.scrub("mytokenstuff=value") == "mytokenstuff=value")
    }

    @Test func preservesDottedIdentifiers() {
        for sample in ["dev.cmux.ios", "ai.manaflow.cmux.ios", "studio.local", "1.2.3", "0.64.0"] {
            #expect(scrubber.scrub(sample) == sample)
        }
    }

    @Test func preservesNormalTerminalOutput() {
        let sample = "$ ls -la\ntotal 8\ndrwxr-xr-x  3 user staff   96 Jun  5 16:00 ."
        #expect(scrubber.scrub(sample) == sample)
    }
}
