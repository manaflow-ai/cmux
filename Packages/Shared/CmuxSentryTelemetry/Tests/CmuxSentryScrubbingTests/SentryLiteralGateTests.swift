import Foundation
import Testing

@testable import CmuxSentryScrubbing

/// The literal gate (``SentryLiteralProbe``) only skips regexes that cannot match: a gated scrubber
/// gives the same output as the ungated rules on every text, and still redacts every secret.
@Suite struct SentryLiteralGateTests {
    private let gated = SentryScrubber(homeDirectory: "/Users/dev", gatesByLiterals: true)
    private let ungated = SentryScrubber(homeDirectory: "/Users/dev", gatesByLiterals: false)

    /// Pieces that make up secrets, near-misses and plain text, in both cases, with non-ASCII
    /// characters ICU's case folding matches to ASCII letters (Kelvin sign, long s).
    private static let pieces: [String] = [
        "token", "TOKEN", "api_key", "Api-Key", "session", "session_id", "secret", "passwd", "Password", "pwd",
        "credentials", "cookie", "bearer", "Bearer ", "auth", "Authorization: ", "Basic ", "sid", "inside",
        "=", ":", " = ", "\"", "'", "\\\"", "&", ",", "}", " ", "\n", "/", ".", "-", "_", "@", "://",
        "sk-", "ghp_", "xoxb-", "github_pat_", "glpat-", "npm_", "hf_", "AIza", "eyJ", "AKIA", "ASIA",
        "abcdefghijklmnop", "ABCDEFGHIJKLMNOPQRST", "0123456789", "4111", "1111", "123-45-6789", "DE89", "3704",
        "-----BEGIN RSA PRIVATE KEY-----", "-----END RSA PRIVATE KEY-----", "MIIEvQ",
        "https://", "user:pw@host", "alice@example.com", "/Users/", "/Users/dev", "/USERS/DEV", "/home/", "alice",
        "focus moved", "workspace 3", "terminal.reveal", "\u{212A}ey", "to\u{212A}en", "\u{017F}ecret", "é", "ß",
    ]

    /// A fixed-seed generator, so a failure names a text that fails again.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func gatedScrubMatchesTheUngatedRulesOnRandomTexts() {
        var random = SplitMix64(state: 0xC0FFEE)
        var mismatches: [String] = []
        for _ in 0..<20_000 {
            let count = Int.random(in: 1...10, using: &random)
            let text = (0..<count).map { _ in Self.pieces.randomElement(using: &random)! }.joined()
            if gated.scrub(text) != ungated.scrub(text) { mismatches.append(text) }
        }
        #expect(mismatches.isEmpty, "gated and ungated scrubs differ on: \(mismatches.prefix(5))")
    }

    /// The secrets of a lag-spike event's breadcrumbs and context are still redacted with the gate on.
    @Test(arguments: [
        ("request failed: Authorization: Bearer abcdef0123456789", "abcdef0123456789"),
        ("env MY_API_KEY=sk-live-0123456789abcdefgh", "sk-live-0123456789abcdefgh"),
        ("{\"password\":\"hunter2&more\"}", "hunter2"),
        ("callback ?sid=s3ss10n&page=2", "s3ss10n"),
        ("pushed with ghp_0123456789abcdefghij", "ghp_0123456789abcdefghij"),
        ("jwt eyJhbGciOi.eyJzdWIiOi.c2lnbmF0dXJl", "eyJzdWIiOi"),
        ("aws AKIAIOSFODNN7EXAMPLE", "AKIAIOSFODNN7EXAMPLE"),
        ("card 4111 1111 1111 1111", "4111 1111 1111 1111"),
        ("mail alice@example.com", "alice@example.com"),
        ("redis://admin:pw@db.internal/0", "admin:pw"),
        ("opened /Users/alice/project", "alice"),
        ("opened /home/bob/project", "bob"),
        ("opened /Users/dev/.config", "/Users/dev"),
        // Non-ASCII text runs every rule: ICU folds the Kelvin sign to `k`.
        ("caf\u{E9} to\u{212A}en=s3cr3tvalue", "s3cr3tvalue"),
    ])
    func secretsAreStillRedacted(text: String, secret: String) {
        let scrubbed = gated.scrub(text)
        #expect(!scrubbed.contains(secret), "\(scrubbed)")
        #expect(scrubbed == ungated.scrub(text))
    }

    @Test func plainTextIsUnchanged() {
        for text in ["focus moved to workspace 3", "terminal.reveal: surface 12 shown", "main thread stalled 312 ms"] {
            #expect(gated.scrub(text) == text)
        }
    }

    @Test func probeFindsLiteralsIgnoringASCIICaseOnly() {
        let probe = SentryLiteralProbe("Header AUTHORIZATION: x")
        #expect(probe.mayContain(Array("authorization:".utf8)))
        #expect(probe.mayContain(Array(":".utf8)))
        #expect(!probe.mayContain(Array("bearer".utf8)))
        #expect(!probe.mayContain(Array("@".utf8)))
        // A non-ASCII text may contain anything.
        #expect(SentryLiteralProbe("caf\u{E9}").mayContain(Array("bearer".utf8)))
    }
}
