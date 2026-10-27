public import Foundation

/// The maintained denylists ``SentryScrubber`` consumes: sensitive dictionary
/// key markers (ported from sentry-python) and free-text value regexes (ported
/// from Sentry's relay `@common` scrubbers, plus cmux's own provider-key / JWT /
/// AWS additions that exceed relay's set).
///
/// The lists live here, separated from the transformer, so their provenance is
/// auditable and drift against upstream is mechanical to review: each block
/// pins the exact upstream repository, commit SHA, and source `file:line` it was
/// ported from. "We missed an alias" becomes "diff upstream since the pinned SHA
/// and bump it," not a regex authored under review pressure.
///
/// This type holds only `static let` *data declarations* (the package's
/// "`static let` is fine for declarations" carve-out); it owns no runtime state
/// and is never instantiated.
///
/// ## Capture-group convention
///
/// Every regex in ``valuePatterns`` is authored for ``SentryScrubber``'s
/// redaction loop, where **capture group 1, if present, is a prefix to KEEP**
/// (e.g. `token=`) and the rest of the match is replaced. This is the *opposite*
/// of relay's `@pemkey` / `@urlauth`, which capture group 1 as the secret to
/// redact. Relay's value patterns are therefore ported with **no capture group**
/// (the whole match is the secret, replaced wholesale). relay's `@urlauth` is
/// deliberately *not* ported here because ``SentryScrubber`` already strips URL
/// userinfo in `redactURLCredentials` with the keep-the-scheme convention.
public struct ScrubberDenylists: Sendable {
    // MARK: - Sensitive dictionary-key markers

    /// Substrings that mark a dictionary/header key as secret-bearing.
    ///
    /// `SentryScrubber.isSensitiveKey(_:)` normalizes a key (lowercase, strip
    /// `-`/`_`/space) and redacts wholesale if it *contains* any marker here, so
    /// a marker also catches longer identifiers (`AWS_SECRET_ACCESS_KEY` →
    /// `secret`, `MY_API_KEY` → `apikey`, `sessionid`/`aiohttp_session`/
    /// `user_session` → `session`, `csrftoken`/`x_csrftoken`/`xsrf-token` →
    /// `token`, `x_api_key` → `apikey`, `set_cookie` → `cookie`).
    ///
    /// Ported from sentry-python `DEFAULT_DENYLIST` (key-name denylist), which
    /// sentry-python itself credits as "stolen from relay". cmux's substring
    /// semantics are intentionally stronger than sentry-python's exact-match
    /// (`k.lower() in denylist`); the upstream entries that already contain one
    /// of these markers are covered by the substring rule and are not duplicated.
    /// Short or marker-free upstream keys live in ``sensitiveKeyExactMarkers``.
    ///
    /// Upstream: getsentry/sentry-python @ 9e54e149a095d15e90f664b9e2ef35796f37e83b
    ///   sentry_sdk/scrubber.py:15-53 (`DEFAULT_DENYLIST`).
    static let sensitiveKeyMarkers: [String] = [
        // High-value credential markers (sentry-python DEFAULT_DENYLIST core).
        "password",     // scrubber.py:16
        "passwd",       // scrubber.py:17
        "secret",       // scrubber.py:18
        "apikey",       // scrubber.py:19-20 (api_key / apikey, normalized)
        "auth",         // scrubber.py:21 (also covers authorization, proxy-authorization)
        "credential",   // scrubber.py:22 (credentials; "credential" covers singular/plural)
        "privatekey",   // scrubber.py:23-24 (privatekey / private_key, normalized)
        "token",        // scrubber.py:25 (also covers csrftoken, x_csrftoken, xsrf-token)
        "session",      // scrubber.py:26 (also covers sessionid, aiohttp_session, user_session, _session)
        "cookie",       // scrubber.py:35 (also covers set_cookie)
        "authorization", // scrubber.py:36 (kept explicit even though "auth" subsumes it)
        // cmux-original markers retained (not in sentry-python's list) so no
        // existing behavior regresses. `accesskey` catches AWS_ACCESS_KEY_ID /
        // SECRET_ACCESS_KEY; `bearer` catches a `bearer`-named field.
        "accesskey",
        "bearer",
    ]

    /// Short or marker-free credential key aliases matched WHOLE (not as
    /// substrings), so they don't redact innocuous keys that merely contain them
    /// (e.g. `sid` must not match `inside`/`aside`; `su` must not match
    /// `issue`/`consumer`).
    ///
    /// These are stored **already normalized** the same way
    /// `SentryScrubber.isSensitiveKey(_:)` normalizes (lowercase, strip
    /// `-`/`_`/space) because the set is consulted *after* normalization. The raw
    /// underscored upstream spellings (`x_real_ip`, `remote_addr`, `_csrf`) would
    /// never fire if stored verbatim, so they are normalized here.
    ///
    /// Ported from sentry-python `DEFAULT_DENYLIST` + `DEFAULT_PII_DENYLIST`
    /// (PII keys added because cmux runs with `sendDefaultPii = false`), with the
    /// session/CSRF cookie aliases relay also ships.
    ///
    /// Upstream:
    /// - getsentry/sentry-python @ 9e54e149a095d15e90f664b9e2ef35796f37e83b
    ///   sentry_sdk/scrubber.py:39-52 (`DEFAULT_DENYLIST` framework/session/CSRF
    ///   aliases) and :55-60 (`DEFAULT_PII_DENYLIST`).
    /// - getsentry/relay @ 99c91d92845fe436713b51018a7f8d2b7b469be5
    ///   relay-pii/src/convert.rs:30-56 (`SENSITIVE_COOKIES`) for `sentrysid`,
    ///   `__session`, `fasthttpsessionid`, `irissessionid`, `_vercel_jwt`, etc.
    static let sensitiveKeyExactMarkers: Set<String> = [
        // sentry-python framework/session/CSRF aliases (normalized).
        "sid",          // bare session alias (Express connect.sid leaf, common in the wild)
        "connect.sid",  // scrubber.py:43 (Express; the dot survives normalization)
        "csrf",         // scrubber.py:46, 48 (csrf / _csrf, normalized)
        "csrftoken",    // scrubber.py:45 (csrf_token, normalized) — also caught by "token" substring
        "xsrf",         // scrubber.py:52 (XSRF-TOKEN leaf), and _xsrf
        "phpsessid",    // scrubber.py:49 (PHP)
        "symfony",      // scrubber.py:50 (Symfony)
        "mysqlpwd",     // scrubber.py:23 (mysql_pwd, normalized)
        // sentry-python DEFAULT_PII_DENYLIST (cmux sends sendDefaultPii = false).
        "xforwardedfor", // scrubber.py:34, 56 (x_forwarded_for, normalized)
        "xrealip",       // scrubber.py:57 (x_real_ip, normalized)
        "ipaddress",     // scrubber.py:58 (ip_address, normalized)
        "remoteaddr",    // scrubber.py:59 (remote_addr, normalized)
        // relay SENSITIVE_COOKIES aliases not implied by a substring marker.
        "sentrysid",        // convert.rs:32 (Sentry default session cookie)
        "su",               // convert.rs:34 (Sentry superuser cookie)
        "fasthttpsessionid", // convert.rs:40
        "irissessionid",    // convert.rs:42
        "verceljwt",        // convert.rs:43 (_vercel_jwt, normalized)
        "fastcsrf",         // convert.rs:54
        "iriscsrf",         // convert.rs:55 (_iris_csrf, normalized)
    ]

    // MARK: - Free-text value regexes

    /// The first line of a PEM private or public key block (relay @pemkey).
    ///
    /// relay matches the whole block with one lazy regex and captures group 1
    /// (the body); cmux redacts the WHOLE block (header, body, footer), so the
    /// base64 body never survives. ``SentryScrubber`` pairs this line with the
    /// next ``pemFooter`` itself instead of running relay's
    /// `BEGIN…[\s\S]+?…END` regex: on text with many headers and no footer
    /// that regex rescans to the end of the text from every header (quadratic),
    /// and a block cut before its footer would not match at all and leak the
    /// key. A header with no footer after it is redacted to the end of the text.
    /// Ported from relay PEM_KEY_REGEX, relay-pii/src/regexes.rs:300-316
    /// (getsentry/relay @ 99c91d92845fe436713b51018a7f8d2b7b469be5).
    static let pemHeader = SentryRegexPattern(#"-----BEGIN[A-Z ]{1,64}(?:PRIVATE|PUBLIC) KEY-----"#)

    /// The last line of a PEM key block; see ``pemHeader``.
    static let pemFooter = SentryRegexPattern(#"-----END[A-Z ]{1,64}(?:PRIVATE|PUBLIC) KEY-----"#)

    /// The ordered secret / token / key / financial value patterns applied
    /// to every free-text string, in priority order.
    ///
    /// Patterns that capture a field prefix in group 1 (e.g. `token=`) keep that
    /// prefix in the output so the redacted field stays legible; patterns with no
    /// capture group replace the whole match with the secret placeholder.
    ///
    /// The first nine entries are cmux-original and partly exceed relay (relay
    /// has no provider-prefix, JWT, or AWS-access-key rule); they keep their
    /// exact `options:` (JWT and AWS are case-sensitive on purpose). The
    /// trailing entries are the relay `@common` value rules cmux was missing,
    /// ported with no capture group so cmux's "group 1 is a prefix to keep"
    /// loop redacts the whole match.
    ///
    /// Every pattern runs in time linear in its input (p10-stability-191):
    /// ICU's matcher backtracks, so a quantifier that can rescan the same text
    /// from many start positions is capped or possessive. Chromium runs
    /// untrusted text through RE2, which is linear by construction
    /// (third_party/re2); Foundation has no such engine, so the bound is in the
    /// patterns and in ``SentryScrubber/maxScrubbedScalars``.
    ///
    /// Upstream for the relay-ported entries:
    /// getsentry/relay @ 99c91d92845fe436713b51018a7f8d2b7b469be5,
    /// `@common` bundle members at relay-pii/src/builtin.rs:35-52, with the named
    /// regexes in relay-pii/src/regexes.rs (cited per entry below). relay's
    /// `@email`, `@ip`, `@userpath`, `@bearer`, `@urlauth`, and `@password`
    /// members are intentionally NOT duplicated here: cmux already covers email /
    /// bearer / paths / URL-userinfo / key=value assignments through dedicated
    /// rules (see ``SentryScrubber``), and `@ip` / `@uuid` are deliberately
    /// omitted to avoid redacting version strings and the workspace/surface UUIDs
    /// cmux logs.
    static let valuePatterns: [SentryRegexPattern] = [
        // --- cmux-original rules (partly exceed relay) ---
        // Bearer <token>. Mirrors relay BEARER_TOKEN_REGEX
        // (relay-pii/src/regexes.rs:339) but keeps the `Bearer ` prefix legible.
        SentryRegexPattern(#"(Bearer\s+)[A-Za-z0-9\-._~+/]+=*"#),
        // Authorization: <scheme> <token>  (Basic / Digest / token / etc.)
        SentryRegexPattern(#"(Authorization:\s*\w+\s+)\S+"#),
        // `<sensitive-key> = value` in raw query strings, env-style assignments,
        // or JSON ("key":"value"). The marker set is kept in sync with the
        // key-aware dictionary path (``SentryScrubber/isSensitiveKey(_:)``) so a
        // credential like `auth=…`, `session_id=…`, or `cookie=…` is redacted
        // whether it arrives as a dictionary entry or as raw text. The marker may
        // be embedded in a longer identifier (e.g. AWS_SECRET_ACCESS_KEY,
        // MY_API_KEY), so optional identifier characters are allowed around it.
        // Conceptually the relay PASSWORD_KEY_REGEX / TOKEN_KEY_REGEX analogue
        // (relay-pii/src/regexes.rs:341-345), hand-tuned for cmux's free text.
        //
        // Split into a QUOTED-value rule and an UNQUOTED-value rule because the
        // value terminator is quote-context-dependent: an unquoted query value
        // MUST stop at `&`/`,`/`}` (`?token=X&page=2` has to keep `&page=2`),
        // but those same characters can legitimately appear INSIDE a quoted JSON
        // value (`"password":"a&b"`), where stopping early would leak the
        // suffix. The quoted rule captures the opening value quote in its prefix
        // group and consumes `[^"']*` (everything up to the closing quote); the
        // unquoted rule keeps the delimiter-bounded `[^\s"'&,}]+`. It does not
        // attempt to model escaped quotes inside a quoted value (a regex JSON
        // parser); the structured dict-key layer plus the wholesale Data/user/
        // cookie drops are the real boundary, this free-text pass is best-effort
        // defense-in-depth for raw event messages / stack lines / breadcrumbs.
        //
        // Linear (p10-stability-191): the match starts at the marker (group 1
        // is kept as written, so the output is the same), since a leading
        // `[A-Za-z0-9.\-]*` rescanned a long identifier from each of its
        // characters; the name after the marker is capped at 128 and possessive.
        // Quoted-value form: redact through the closing quote.
        SentryRegexPattern(
            #"((?:access[_\-]?token|api[_\-]?key|access[_\-]?key|private[_\-]?key|session[_\-]?id|session|secret|token|password|passwd|pwd|credentials?|cookie|bearer|auth)[A-Za-z0-9.\-]{0,128}+["']?\s*+[:=]\s*+["'])[^"']*"#
        ),
        // The bare `sid` session alias (`?sid=…`, `&sid=…`, `sid:…`) carries a
        // session credential but is too short to embed in the marker set above
        // without matching innocuous substrings (`inside=`, `aside=`). A `\b`
        // word boundary anchors it so only a standalone `sid` key is redacted.
        // Quoted-value form (same quote-context split as the marker rule above).
        SentryRegexPattern(#"(\bsid["']?\s*[:=]\s*["'])[^"']*"#),
        // Unquoted-value form of the marker rule: delimiter-bounded value.
        SentryRegexPattern(
            #"((?:access[_\-]?token|api[_\-]?key|access[_\-]?key|private[_\-]?key|session[_\-]?id|session|secret|token|password|passwd|pwd|credentials?|cookie|bearer|auth)[A-Za-z0-9.\-]{0,128}+["']?\s*+[:=]\s*+)[^\s"'&,}]+"#
        ),
        // Unquoted-value form of the bare `sid` alias.
        SentryRegexPattern(#"(\bsid["']?\s*[:=]\s*)[^\s"'&,}]+"#),
        // Provider-style keys: sk-..., pk-..., ghp_..., xoxb-..., and similar
        // prefixes. No relay equivalent — cmux-specific add for dev secrets.
        SentryRegexPattern(#"\b(?:sk|pk|rk|ghp|gho|ghu|ghs|ghr|xox[baprs])[_\-][A-Za-z0-9_\-]{16,}"#),
        // JSON Web Tokens: three base64url segments separated by dots. No relay
        // equivalent. Case-sensitive (`eyJ` header is fixed-case base64). The
        // header has no length cap (an x5c JWS header runs to kilobytes) and
        // ends at the next `-eyJ`, the place the next scan starts (`-` breaks
        // `\b`); the first two segments are possessive (no segment character
        // is a `.`). On `eyJ-eyJ-…` each scan so stops at the next `eyJ`, not
        // at the end of the text (p10-stability-191).
        SentryRegexPattern(
            #"\beyJ(?:[A-Za-z0-9_]|-(?!eyJ))++\.[A-Za-z0-9_\-]++\.[A-Za-z0-9_\-]+"#,
            options: []
        ),
        // AWS access key IDs. No relay equivalent. Case-sensitive (AKIA/ASIA + uppercase).
        SentryRegexPattern(#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#, options: []),

        // --- relay @common value rules cmux was missing (ported, no group) ---
        // @pemkey is not here: ``pemHeader`` and ``pemFooter`` pair up blocks.
        // @creditcard — variable-length card number (Amex/Visa/Mastercard/
        // Discover prefixes), dashes/spaces allowed. Whole match redacted.
        // Ported from relay CREDITCARD_REGEX, relay-pii/src/regexes.rs:265-280.
        SentryRegexPattern(
            #"\b(?:3[47]\d|4\d{3}|5[1-5]\d\d|65\d\d|6011)(?:[-\s]?\d){12}\b"#,
            options: []
        ),
        // @iban — country-prefix IBAN. Whole match redacted.
        // Ported from relay IBAN_REGEX, relay-pii/src/regexes.rs:191-197.
        SentryRegexPattern(
            #"\b(?:AT|AD|AE|AL|AZ|BA|BE|BG|BH|BR|BY|CH|CR|CY|CZ|DE|DK|DO|EE|EG|ES|FI|FO|FR|GB|GE|GI|GL|GR|GT|HR|HU|IE|IL|IQ|IS|IT|JO|KW|KZ|LB|LC|LI|LT|LU|LV|LY|MC|MD|ME|MK|MR|MT|MU|NL|NO|PK|PL|PS|PT|QA|RO|RU|RS|SA|SC|SE|SI|SK|SM|ST|SV|TL|TN|TR|UA|VA|VG|XK|DZ|AO|BJ|BF|BI|CV|CM|CF|TD|KM|CG|CI|DJ|GQ|GA|GW|HN|IR|MG|ML|MA|MZ|NI|NE|SN|TG)\d{2}[A-Za-z0-9]{11,29}\b"#
        ),
        // @usssn — US Social Security number `NNN-NN-NNNN`. Whole match redacted.
        // Ported from relay US_SSN_REGEX, relay-pii/src/regexes.rs:329-335.
        SentryRegexPattern(#"\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b"#, options: []),
    ]
}
