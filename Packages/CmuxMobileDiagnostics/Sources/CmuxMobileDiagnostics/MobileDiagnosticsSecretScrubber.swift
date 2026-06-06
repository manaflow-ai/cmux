import Foundation

/// Masks obvious secret patterns in assembled diagnostics text before it leaves
/// the device.
///
/// The diagnostics bundle is shared to multiple internal testers through the
/// system share sheet, and both the terminal snapshot and the log lines can
/// carry live credentials (bearer tokens, API keys, JWTs, `password=` values).
/// ``scrub(_:)`` runs a small set of conservative regular expressions over the
/// whole report and replaces only the secret value with ``redactionMarker``,
/// leaving surrounding text intact.
///
/// The intent is *light* masking, not aggressive sanitization: it must not
/// mangle ordinary terminal output, dotted identifiers (`dev.cmux.ios`), or
/// version strings (`1.2.3`). Each pattern requires structure that ordinary
/// output does not accidentally satisfy (a recognized prefix, a long
/// base64url-charset run, or a `key=value` secret keyword).
///
/// ```swift
/// let scrubber = MobileDiagnosticsSecretScrubber()
/// let clean = scrubber.scrub("Authorization: Bearer abc.def.ghi")
/// // -> "Authorization: Bearer <redacted>"
/// ```
public struct MobileDiagnosticsSecretScrubber: Sendable {
    /// The replacement written in place of a matched secret value.
    public let redactionMarker: String

    private let patterns: [(regex: NSRegularExpression, valueGroup: Int)]

    /// Creates a scrubber.
    ///
    /// - Parameter redactionMarker: The text substituted for each masked secret.
    ///   Defaults to `"<redacted>"`.
    public init(redactionMarker: String = "<redacted>") {
        self.redactionMarker = redactionMarker
        self.patterns = makeMobileDiagnosticsSecretPatterns()
    }

    /// Returns `text` with recognized secret values replaced by ``redactionMarker``.
    ///
    /// Patterns are applied in sequence; a value masked by one pattern is no
    /// longer a candidate for later ones. Non-secret text (identifiers, version
    /// numbers, ordinary output) is left untouched.
    ///
    /// - Parameter text: The assembled report text to scrub.
    /// - Returns: The scrubbed text.
    public func scrub(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            result = replaceMobileDiagnosticsSecretGroup(
                in: result,
                regex: pattern.regex,
                group: pattern.valueGroup,
                with: redactionMarker
            )
        }
        return result
    }
}

/// Replace the contents of one capture group across every match, scanning from
/// the end so earlier match ranges stay valid as the string mutates.
private func replaceMobileDiagnosticsSecretGroup(
    in text: String,
    regex: NSRegularExpression,
    group: Int,
    with replacement: String
) -> String {
    let nsText = text as NSString
    let matches = regex.matches(
        in: text,
        range: NSRange(location: 0, length: nsText.length)
    )
    let mutable = (nsText.mutableCopy() as? NSMutableString) ?? NSMutableString(string: text)
    for match in matches.reversed() {
        guard match.numberOfRanges > group else { continue }
        let valueRange = match.range(at: group)
        guard valueRange.location != NSNotFound else { continue }
        mutable.replaceCharacters(in: valueRange, with: replacement)
    }
    return mutable as String
}

/// Build the conservative pattern set.
///
/// Each entry pairs a regex with the capture group to mask. The patterns are
/// deliberately narrow so normal terminal output is not mangled.
private func makeMobileDiagnosticsSecretPatterns() -> [(regex: NSRegularExpression, valueGroup: Int)] {
    // Base64url alphabet used by JWTs and most opaque tokens.
    let b64url = "[A-Za-z0-9_-]"
    let raw: [(String, Int)] = [
        // PEM private-key blocks from terminal output (`OPENSSH PRIVATE KEY`,
        // `RSA PRIVATE KEY`, `EC PRIVATE KEY`, `PRIVATE KEY`, PGP private key
        // blocks). Redact the whole block, including newlines.
        ("(-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----)", 1),

        // `Bearer <token>` (Authorization headers, curl output). Case-insensitive
        // keyword; the value is any run of token-ish characters.
        ("(?i)(\\bBearer\\s+)([A-Za-z0-9._~+/=-]{8,})", 2),

        // Canonical AWS credential environment variables. These do not all
        // include generic secret keywords in the right shape (`ACCESS_KEY_ID`
        // is the common miss), so cover them explicitly before the generic
        // key/value rule.
        ("(?i)(?:^|[\\s\"'`({\\[,;&?])((?:AWS_(?:ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|SECURITY_TOKEN))\\b\\s*[:=]\\s*[\"']?)([^\\s\"'&]{4,})",
         2),

        // `token=...`, `password=...`, `secret=...`, `api[_-]?key=...`,
        // `access_token=...`, `auth=...` style key/value pairs (query strings,
        // env dumps, config). The optional non-capturing identifier prefix
        // (`(?:[A-Za-z0-9]+[_-])*`) lets `API_TOKEN=`, `GITHUB_TOKEN=`,
        // `DB_PASSWORD=`, `STACK_REFRESH_TOKEN=` match (no `\b` boundary
        // exists inside an UPPER_SNAKE name), which is the dominant shape in
        // `env`/`.env`/`printenv` output a terminal snapshot captures. The
        // trailing `\b` still rejects `tokenizer=` / `mytokenstuff=`. The
        // value capture group stays group 2. Value runs until whitespace,
        // quote, or `&`.
        ("(?i)(?:^|[\\s\"'`({\\[,;&?])(?:[A-Za-z0-9]+[_-])*(?:access[_-]?token|refresh[_-]?token|api[_-]?key|auth[_-]?token|token|password|passwd|secret|client[_-]?secret|x-stack-refresh-token)\\b(\\s*[:=]\\s*[\"']?)([^\\s\"'&]{4,})",
         2),

        // Provider-prefixed keys: OpenAI `sk-...`, GitHub `ghp_/gho_/ghu_/ghs_/ghr_...`,
        // Stack `pck_/sck_...`, generic `key-...`. Require a meaningful length.
        ("\\b((?:sk|pk|rk)-[A-Za-z0-9_-]{16,})", 1),
        ("\\b(gh[pousr]_[A-Za-z0-9]{20,})", 1),
        ("\\b((?:pck|sck|ssk)_[A-Za-z0-9]{16,})", 1),

        // JWT-like `xxx.yyy.zzz`: three base64url segments. Require the middle
        // and last segments to be long so dotted identifiers (`dev.cmux.ios`)
        // and version strings (`1.2.3`) never match: each segment must be
        // base64url and the trailing two segments are >= 8 chars.
        ("\\b(\(b64url){8,}\\.\(b64url){8,}\\.\(b64url){8,})\\b", 1),
    ]
    return raw.compactMap { source, group in
        guard let regex = try? NSRegularExpression(pattern: source) else {
            return nil
        }
        return (regex: regex, valueGroup: group)
    }
}
