import Foundation

struct MobileDiagnosticsSecretPatternFactory {
    /// Build the conservative pattern set.
    ///
    /// Each entry pairs a regex with the capture group to mask. The patterns are
    /// deliberately narrow so normal terminal output is not mangled.
    func makePatterns() -> [(regex: NSRegularExpression, valueGroup: Int)] {
        // Base64url alphabet used by JWTs and most opaque tokens.
        let b64url = "[A-Za-z0-9_-]"
        let stackSecretKey = "stack[_-]?(?:access|refresh)(?:[_-]?token)?|x[_-]stack[_-](?:access|refresh)[_-]token"
        let separatedSecretNames = [
            "access[_-]?token",
            "refresh[_-]?token",
            "api[_-]?key",
            "account[_-]?key",
            "auth[_-]?token",
            "auth",
            "access[_-]?key[_-]?id",
            "secret[_-]?access[_-]?key",
            "storage[_-]?key",
            "session[_-]?token",
            "security[_-]?token",
            "token",
            "password",
            "passwd",
            "private[_-]?key",
            "secret[_-]?key",
            "secret",
            "client[_-]?secret",
            stackSecretKey,
        ].joined(separator: "|")
        let camelSecretNames = [
            "accessToken",
            "refreshToken",
            "apiKey",
            "accountKey",
            "authToken",
            "attachToken",
            "clientSecret",
            "accessKeyId",
            "secretAccessKey",
            "sessionToken",
            "securityToken",
        ].joined(separator: "|")
        let separatedSecretKey = "(?:[A-Za-z0-9]+[_-])*(?:\(separatedSecretNames))"
        let camelSecretKey = "(?:[A-Za-z0-9]+)?(?:\(camelSecretNames))|stack(?:Access|Refresh)(?:Token)?"
        let secretKey = "(?:\(separatedSecretKey)|\(camelSecretKey))"
        let raw: [(String, Int)] = [
            // PEM private-key blocks from terminal output (`OPENSSH PRIVATE KEY`,
            // `RSA PRIVATE KEY`, `EC PRIVATE KEY`, `PRIVATE KEY`, PGP private key
            // blocks). Redact the whole block, including newlines.
            ("(-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----)", 1),

            // `Bearer <token>` (Authorization headers, curl output). Case-insensitive
            // keyword; the value is any run of token-ish characters.
            ("(?i)(\\bBearer\\s+)([A-Za-z0-9._~+/=-]{8,})", 2),

            // `Authorization: Basic <base64>` and other credential-bearing
            // Authorization header schemes. Redact the header value through the
            // end of the line so Digest-style parameters do not leak either.
            ("(?i)(\\b(?:Proxy-)?Authorization\\s*:\\s*(?:Basic|Digest|Negotiate|NTLM|AWS4-HMAC-SHA256)\\s+)([^\\r\\n]{4,})",
             2),

            // Stack-specific auth headers used by the web/API bridge. Redact the
            // whole value, including an optional Bearer prefix, before the generic
            // key/value rule sees `Bearer` as the value.
            ("(?i)(\\bx[_-]stack[_-](?:access|refresh)[_-]token\\s*[:=]\\s*)((?:Bearer\\s+)?[^\\s,;)]+)",
             2),

            // cmux attach/pairing URLs carry base64url JSON payloads. Attach
            // tickets include auth tokens, so redact the opaque payload value
            // whenever those deep links appear in logs or terminal snapshots.
            ("(?i)(\\bcmux-ios://(?:attach|pair)\\?[^\\s\"'<>]*?\\bpayload=)([A-Za-z0-9_-]{8,})",
             2),

            // Canonical AWS credential environment variables. These do not all
            // include generic secret keywords in the right shape (`ACCESS_KEY_ID`
            // is the common miss), so cover them explicitly before the generic
            // key/value rule.
            ("(?i)(?:^|[\\s\"'`({\\[,;&?])((?:AWS_(?:ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN|SECURITY_TOKEN))\\b\\s*[:=]\\s*[\"']?)([^\\s\"'&]{4,})",
             2),

            // npm registry auth tokens in `.npmrc` output can appear as either
            // `_authToken=...` or `//registry.example/:_authToken=...`.
            ("(?i)(?:^|[\\s\"'`({\\[,;&?:])(_authToken\\b\\s*[:=]\\s*[\"']?)([^\\s\"'&]{4,})",
             2),

            // Azure Storage connection strings use `;AccountKey=...;`.
            // Stop at the next semicolon so later non-secret fields stay visible.
            ("(?i)(\\bAccountKey\\s*=\\s*)([^;\\r\\n]{4,})", 2),

            // Quoted `token=\"...\"` / `password='...'` style values can include
            // spaces. Handle those before the unquoted rule below so the whole
            // quoted value is redacted instead of only its first word.
            ("(?i)(?:^|[\\s\"'`({\\[,;&?#])\(secretKey)\\b(\\s*[:=]\\s*\")([^\"\\r\\n]{4,})\"",
             2),
            ("(?i)(?:^|[\\s\"'`({\\[,;&?#])\(secretKey)\\b(\\s*[:=]\\s*')([^'\\r\\n]{4,})'",
             2),

            // JSON or JavaScript object output, e.g.
            // `"access_token":"..."`, `"stackAccessToken":"..."`, or
            // `'password': '...'`.
            ("(?i)(\"\(secretKey)\\b\"\\s*:\\s*\")([^\"\\r\\n]{4,})(\")",
             2),
            ("(?i)('\(secretKey)\\b'\\s*:\\s*')([^'\\r\\n]{4,})(')",
             2),

            // `token=...`, `password=...`, `secret=...`, `api[_-]?key=...`,
            // `access_token=...`, `stackAccessToken=...`, `auth=...` style
            // key/value pairs (query strings, env dumps, config). The prefix
            // alternatives let `API_TOKEN=`, `STACK_REFRESH_TOKEN=`, and
            // `stackAccessToken=` match while the trailing `\b` still rejects
            // `tokenizer=` / `mytokenstuff=`. The value capture group stays
            // group 2. Value runs until whitespace, quote, `&`, or `;`.
            ("(?i)(?:^|[\\s\"'`({\\[,;&?#])\(secretKey)\\b(\\s*[:=]\\s*[\"']?)([^\\s\"'&;]{4,})",
             2),

            // Connection URLs with userinfo credentials, e.g.
            // `postgres://user:password@host` or `redis://:password@host`.
            ("(?i)\\b([A-Za-z][A-Za-z0-9+.-]{1,32}://[^\\s/?#@]*?:)([^\\s/?#@]{4,})(@)", 2),

            // Provider-prefixed keys: OpenAI `sk-...`, GitHub
            // `ghp_/gho_/ghu_/ghs_/ghr_...`, Slack `xox...`, Stack
            // `pck_/sck_...`, generic `key-...`. Require a meaningful length.
            ("\\b((?:sk|pk|rk)-[A-Za-z0-9_-]{16,}|(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,})", 1),
            ("\\b(github_pat_[A-Za-z0-9_]{20,})\\b", 1),
            ("\\b(gh[pousr]_[A-Za-z0-9]{20,})", 1),
            ("\\b(glpat-[A-Za-z0-9_-]{20,})\\b", 1),
            ("\\b((?:xox[abprs]|xapp)-[A-Za-z0-9-]{16,})\\b", 1),
            ("\\b(AIza[A-Za-z0-9_-]{20,})\\b", 1),
            ("\\b(npm_[A-Za-z0-9_-]{20,})\\b", 1),
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
}
