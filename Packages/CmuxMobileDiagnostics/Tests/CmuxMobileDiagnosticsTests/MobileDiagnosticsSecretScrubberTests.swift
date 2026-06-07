import Foundation
import Testing
@testable import CmuxMobileDiagnostics

@Suite struct MobileDiagnosticsSecretScrubberTests {
    private let scrubber = MobileDiagnosticsSecretScrubber()

    @Test func redactsBearerToken() {
        let out = scrubber.scrub("Authorization: Bearer abcDEF123.ghi_jkl-mno")
        #expect(out == "Authorization: Bearer <redacted>")
    }

    @Test func redactsBasicAuthorizationHeader() {
        let out = scrubber.scrub("Authorization: Basic dXNlcjpwYXNzd29yZA==")
        #expect(out == "Authorization: Basic <redacted>")
        #expect(!out.contains("dXNlcjpwYXNzd29yZA"))
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
        #expect(scrubber.scrub("API_TOKEN='opaquevalue123'") == "API_TOKEN='<redacted>'")
        #expect(scrubber.scrub("DB_PASSWORD='hunter2longvalue'") == "DB_PASSWORD='<redacted>'")
        #expect(scrubber.scrub("AUTH=opaque-secret-123") == "AUTH=<redacted>")
        #expect(scrubber.scrub("_authToken=npm_secret_value_123") == "_authToken=<redacted>")
        #expect(
            scrubber.scrub("//registry.npmjs.org/:_authToken=npm_secret_value_456")
                == "//registry.npmjs.org/:_authToken=<redacted>"
        )
    }

    @Test func redactsQuotedKeyValueSecretsContainingSpaces() {
        let samples = [
            ("PASSWORD='correct horse battery staple'", "PASSWORD='<redacted>'", "horse battery"),
            ("client_secret=\"super secret oauth value\"", "client_secret=\"<redacted>\"", "oauth value"),
            ("api_key: 'key with spaces inside'", "api_key: '<redacted>'", "spaces inside"),
            ("auth=\"opaque auth value\"", "auth=\"<redacted>\"", "auth value"),
        ]

        for (sample, expected, leakedFragment) in samples {
            let out = scrubber.scrub(sample)
            #expect(out == expected)
            #expect(!out.contains(leakedFragment), "value leaked for \(sample): \(out)")
        }
    }

    @Test func redactsJSONKeyValueSecrets() {
        let samples = [
            (#"{"access_token":"opaque-refresh-token-1234"}"#, #"{"access_token":"<redacted>"}"#, "refresh-token"),
            (#"{"authToken":"opaque-auth-token-1234"}"#, #"{"authToken":"<redacted>"}"#, "auth-token"),
            (#"{"refreshToken":"opaque-refresh-token-5678"}"#, #"{"refreshToken":"<redacted>"}"#, "refresh-token"),
            (#"{"stackAccessToken":"opaque-stack-token-1234"}"#, #"{"stackAccessToken":"<redacted>"}"#, "stack-token"),
            (#"{"password":"hunter2longvalue"}"#, #"{"password":"<redacted>"}"#, "hunter2longvalue"),
            (#"{"auth":"opaque-secret-123"}"#, #"{"auth":"<redacted>"}"#, "opaque-secret"),
            ("{'client_secret': 'oauth secret value'}", "{'client_secret': '<redacted>'}", "oauth secret"),
        ]

        for (sample, expected, leakedFragment) in samples {
            let out = scrubber.scrub(sample)
            #expect(out == expected)
            #expect(!out.contains(leakedFragment), "value leaked for \(sample): \(out)")
        }
    }

    @Test func redactsCamelCaseTokenFields() {
        let samples = [
            ("accessToken=opaque-access-token-1234", "accessToken=<redacted>", "access-token"),
            ("refreshToken: opaque-refresh-token-1234", "refreshToken: <redacted>", "refresh-token"),
            ("authToken='opaque-auth-token-1234'", "authToken='<redacted>'", "auth-token"),
            ("stackAccessToken=opaque-stack-token-1234", "stackAccessToken=<redacted>", "stack-token"),
            ("attachToken=\"opaque-attach-token-1234\"", "attachToken=\"<redacted>\"", "attach-token"),
        ]

        for (sample, expected, leakedFragment) in samples {
            let out = scrubber.scrub(sample)
            #expect(out == expected)
            #expect(!out.contains(leakedFragment), "value leaked for \(sample): \(out)")
        }
    }

    @Test func redactsConnectionURLCredentials() {
        let samples = [
            ("DATABASE_URL=postgres://user:dbpass1234@example.com/app", "DATABASE_URL=postgres://user:<redacted>@example.com/app", "dbpass1234"),
            ("REDIS_URL=redis://:cachepass123@host:6379", "REDIS_URL=redis://:<redacted>@host:6379", "cachepass123"),
            ("PG_URL=postgres://user:pa:ssword123@db.internal/app", "PG_URL=postgres://user:<redacted>@db.internal/app", "pa:ssword123"),
        ]

        for (sample, expected, leakedFragment) in samples {
            let out = scrubber.scrub(sample)
            #expect(out == expected)
            #expect(!out.contains(leakedFragment), "value leaked for \(sample): \(out)")
        }
    }

    @Test func redactsCmuxAttachPayloads() {
        let attachPayload = "eyJ2ZXJzaW9uIjoxLCJhdXRoX3Rva2VuIjoidGlja2V0LXNlY3JldCJ9"
        let pairPayload = "eyJ2ZXJzaW9uIjoxLCJtYWNfZGV2aWNlX2lkIjoiTUFDLTEifQ"
        let samples = [
            (
                "open cmux-ios://attach?v=1&payload=\(attachPayload)",
                "open cmux-ios://attach?v=1&payload=<redacted>",
                attachPayload
            ),
            (
                "scan cmux-ios://pair?payload=\(pairPayload)&v=1",
                "scan cmux-ios://pair?payload=<redacted>&v=1",
                pairPayload
            ),
        ]

        for (sample, expected, leakedPayload) in samples {
            let out = scrubber.scrub(sample)
            #expect(out == expected)
            #expect(!out.contains(leakedPayload), "payload leaked for \(sample): \(out)")
        }
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
        let authURL = "https://example.com/callback?auth=opaque-secret-123&ok=1"
        let scrubbedAuthURL = scrubber.scrub(authURL)
        #expect(scrubbedAuthURL.contains("auth=<redacted>"))
        #expect(!scrubbedAuthURL.contains("opaque-secret-123"))
    }

    @Test func redactsProviderPrefixedKeys() {
        #expect(scrubber.scrub("sk-abcdefghij0123456789xyz").contains("<redacted>"))
        #expect(scrubber.scrub("const key = \"sk-proj-abcdefghij0123456789xyz\"").contains("<redacted>"))
        #expect(!scrubber.scrub("const key = \"sk-proj-abcdefghij0123456789xyz\"").contains("sk-proj"))
        #expect(scrubber.scrub("ghp_abcdefghij0123456789abcdef").contains("<redacted>"))
        #expect(scrubber.scrub("github_pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz_abcdefghijklmno").contains("<redacted>"))
        #expect(!scrubber.scrub("github_pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz_abcdefghijklmno").contains("github_pat_"))
    }

    @Test func redactsPrivateKeyBlocks() {
        let openSSH = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAA
        -----END OPENSSH PRIVATE KEY-----
        """
        let rsa = """
        prefix
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAtestprivatekeypayload
        -----END RSA PRIVATE KEY-----
        suffix
        """

        let scrubbedOpenSSH = scrubber.scrub(openSSH)
        let scrubbedRSA = scrubber.scrub(rsa)

        #expect(scrubbedOpenSSH == "<redacted>")
        #expect(scrubbedRSA.contains("<redacted>"))
        #expect(!scrubbedRSA.contains("testprivatekeypayload"))
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
            ("AWS_ACCESS_KEY_ID='AKIAIOSDIAGNOSTICS123'", "AKIAIOSDIAGNOSTICS123"),
            ("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "wJalrXUtnFEMI"),
            ("AWS_SECRET_ACCESS_KEY='wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'", "wJalrXUtnFEMI"),
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
        #expect(scrubber.scrub("author=lawrence") == "author=lawrence")
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

    @Test func preservesNonCmuxPayloadParameters() {
        let sample = "https://example.com/submit?payload=ordinaryPayloadValue123"
        #expect(scrubber.scrub(sample) == sample)
    }
}
