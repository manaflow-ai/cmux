import Foundation
import Testing

@testable import CmuxFoundation

/// Table-driven behavior tests for the maintained denylists ported into
/// ``ScrubberDenylists``.
///
/// Every case scrubs a representative secret/PII string drawn from the upstream
/// corpora (sentry-python `DEFAULT_DENYLIST` keys, relay `@common` value rules
/// and `SENSITIVE_COOKIES` aliases) and asserts the redacted output. These are
/// behavioral assertions (scrub in → expect redacted out), never source-shape
/// checks. They are the anti-drift fixtures: if an upstream alias is dropped
/// from the ported lists, the matching case fails.
@Suite struct ScrubberDenylistsTests {
    /// A scrubber with a fixed home directory so path redaction is deterministic.
    private let scrubber = SentryScrubber(homeDirectory: "/Users/lawrence")

    // MARK: - sentry-python DEFAULT_DENYLIST / DEFAULT_PII_DENYLIST keys

    /// Keys from sentry-python's denylists (and relay's sensitive-cookie list)
    /// that must be treated as sensitive dictionary keys. Each is the key under
    /// which a credential lives; the value is redacted wholesale by name.
    ///
    /// Spelled the way they appear upstream / in the wild (underscores, dashes,
    /// mixed case) to prove `isSensitiveKey`'s normalization closes the holes the
    /// hand-rolled list missed (`connect.sid`, `phpsessid`, `symfony`,
    /// `mysql_pwd`, `_csrf`, `_xsrf`, and the PII keys `x_forwarded_for`,
    /// `x_real_ip`, `ip_address`, `remote_addr`).
    static let sensitiveKeys: [String] = [
        // core
        "password", "passwd", "secret", "api_key", "apikey", "auth",
        "credentials", "mysql_pwd", "privatekey", "private_key", "token",
        "session",
        // django / framework
        "csrftoken", "sessionid", "x_csrftoken", "set_cookie", "cookie",
        "authorization", "proxy-authorization", "x_api_key",
        // in the wild
        "aiohttp_session", "connect.sid", "csrf_token", "csrf", "_csrf",
        "_csrf_token", "PHPSESSID", "_session", "symfony", "user_session",
        "_xsrf", "XSRF-TOKEN",
        // PII (cmux runs sendDefaultPii = false)
        "x_forwarded_for", "x_real_ip", "ip_address", "remote_addr",
        // relay SENSITIVE_COOKIES aliases
        "sentrysid", "su", "fasthttpsessionid", "irissessionid", "_vercel_jwt",
        "fastcsrf", "_iris_csrf", "__session", "phpsessid",
    ]

    @Test(arguments: sensitiveKeys)
    func denylistedKeyIsTreatedAsSensitive(_ key: String) {
        #expect(SentryScrubber.isSensitiveKey(key), "expected '\(key)' to be a sensitive key")
        // And the value behind it is redacted wholesale, regardless of shape.
        let output = scrubber.scrub(dictionary: [key: "plainvalue123notapattern"])
        #expect(
            output[key] as? String == SentryScrubber.redactedSecret,
            "expected value under '\(key)' to be redacted"
        )
    }

    /// Keys that merely *contain* a denylisted alias but are not credentials must
    /// pass through, proving the short aliases are whole-word matched and don't
    /// over-redact (the `sid`→`inside`, `su`→`issue` false-positive class).
    static let nonSensitiveKeys: [String] = [
        "username", "count", "path", "inside", "aside", "presidency",
        "issue", "consumer", "describe",
    ]

    @Test(arguments: nonSensitiveKeys)
    func nonCredentialKeyIsNotSensitive(_ key: String) {
        #expect(!SentryScrubber.isSensitiveKey(key), "expected '\(key)' to NOT be sensitive")
    }

    // MARK: - relay @common value rules: secrets that must redact

    /// `(input, expected)` pairs for the value-regex layer. Inputs are
    /// representative secrets/PII (relay `@common` corpora plus cmux's own); each
    /// expects the secret replaced by a redaction placeholder while surrounding
    /// context survives.
    static let valueRedactions: [(input: String, expected: String)] = [
        // @pemkey — the whole PEM block (header, base64 body, footer) is gone.
        (
            "key -----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEAsecretbodyabc/def+ghi==\n-----END RSA PRIVATE KEY----- done",
            "key <redacted-secret> done"
        ),
        (
            "-----BEGIN PRIVATE KEY-----\nMIIBVwIBADANBgkqhkiG9w0BAQEFAAS\n-----END PRIVATE KEY-----",
            "<redacted-secret>"
        ),
        (
            "-----BEGIN EC PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQ\n-----END EC PUBLIC KEY-----",
            "<redacted-secret>"
        ),
        // @creditcard — Visa / Amex / Mastercard, with and without separators.
        ("paid with 4111 1111 1111 1111 today", "paid with <redacted-secret> today"),
        ("amex 378282246310005 charged", "amex <redacted-secret> charged"),
        ("mc 5555-5555-5555-4444 ok", "mc <redacted-secret> ok"),
        // @iban — country-prefixed IBAN.
        ("transfer to DE89370400440532013000 now", "transfer to <redacted-secret> now"),
        ("iban GB82WEST12345698765432 fine", "iban <redacted-secret> fine"),
        // @usssn — US SSN.
        ("ssn 123-45-6789 on file", "ssn <redacted-secret> on file"),
        // @urlauth equivalent (cmux redactURLCredentials) — userinfo stripped.
        ("git remote https://user:pass@github.com/x.git", "git remote https://<redacted-secret>@github.com/x.git"),
        // @bearer.
        ("hdr Bearer abc123DEF456ghi789xyz end", "hdr Bearer <redacted-secret> end"),
        // @password key=value family (relay PASSWORD_KEY_REGEX analogue).
        ("the_password=hunter2hunter2 set", "the_password=<redacted-secret> set"),
        ("api_key=plainlettersvalue123 used", "api_key=<redacted-secret> used"),
        ("connecting with mysql_pwd=rootpassword123", "connecting with mysql_pwd=<redacted-secret>"),
        // cmux-original provider key / JWT / AWS (exceed relay).
        ("call sk-proj-abcdef0123456789ABCDEF now", "call <redacted-secret> now"),
        ("clone ghp_0123456789abcdefABCDEF0123456789abcd here", "clone <redacted-secret> here"),
        ("creds AKIAIOSFODNN7EXAMPLE rejected", "creds <redacted-secret> rejected"),
        // Quoted JSON values whose secret contains a delimiter (`&`, `,`, `}`)
        // must redact through the CLOSING quote, not stop at the delimiter and
        // leak the tail (the quote-context split). These are the exact shapes a
        // raw event message / breadcrumb / NSError description arrives as.
        (#"{"password":"abc&def"}"#, #"{"password":"<redacted-secret>"}"#),
        (#"{"token":"a,b,c"}"#, #"{"token":"<redacted-secret>"}"#),
        (#"{"api_key":"k&v}x"}"#, #"{"api_key":"<redacted-secret>"}"#),
        (#"cookie="ab&cd""#, #"cookie="<redacted-secret>""#),
        // Unquoted value: the delimiter is a real field separator and must still
        // bound the value (so a trailing `&page=2` / `,KEEP=` field survives).
        ("GET /x?token=supersecret123&page=2", "GET /x?token=<redacted-secret>&page=2"),
        ("env TOKEN=plainvalue,KEEP=2", "env TOKEN=<redacted-secret>,KEEP=2"),
    ]

    @Test(arguments: valueRedactions)
    func valuePatternRedactsSecret(_ pair: (input: String, expected: String)) {
        #expect(scrubber.scrub(pair.input) == pair.expected)
    }

    /// A PEM key block must have its base64 body absent from the output, not
    /// merely followed by a placeholder (guards the relay capture-group
    /// inversion: relay redacts group 1 = body, cmux redacts the whole match).
    @Test func pemKeyBodyDoesNotSurvive() {
        let body = "MIIEpAIBAAKCAQEAsecretkeymaterialdoesnotleak"
        let input = "leak? -----BEGIN RSA PRIVATE KEY-----\n\(body)\n-----END RSA PRIVATE KEY-----"
        let output = scrubber.scrub(input)
        #expect(!output.contains(body), "PEM body leaked: \(output)")
        #expect(!output.contains("BEGIN RSA PRIVATE KEY"), "PEM header leaked: \(output)")
        #expect(output.contains("<redacted-secret>"))
    }

    // MARK: - Negative fixtures: must NOT over-redact

    /// Strings that look secret-adjacent but carry no secret; the financial /
    /// PEM / key rules run over all free text, so they must not false-positive on
    /// these. Output must equal input.
    static let preservedStrings: [String] = [
        // UUIDs cmux logs constantly (workspace/surface ids). @uuid intentionally not ported.
        "workspace 550e8400-e29b-41d4-a716-446655440000 ready",
        "surface 123e4567-e89b-12d3-a456-426614174000 attached",
        // Build/version numbers must not trip @creditcard or @usssn.
        "cmux DEV build 1234567890 v2",
        "version 0.64.13 (build 4521)",
        // A normal stack trace line.
        "at GhosttyTerminalView.forceRefresh() line 142 in frame 7",
        // Plain error text.
        "Fatal error: Index out of range while reading buffer",
        // A short numeric grouping line that is not an SSN (wrong digit shape).
        "code=42 status=ok retry=true id=ABC123",
    ]

    @Test(arguments: preservedStrings)
    func preservesNonSecretString(_ input: String) {
        #expect(scrubber.scrub(input) == input)
    }
}
