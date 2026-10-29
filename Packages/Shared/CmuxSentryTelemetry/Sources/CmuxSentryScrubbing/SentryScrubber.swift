public import Foundation

/// Redacts privacy-sensitive content out of strings and nested values before
/// they leave the device in a crash/error report.
///
/// ``SentryScrubber`` is a pure value transformer with no Sentry dependency: it
/// scrubs plain `String` values and recursively walks `[String: Any]` /
/// `[Any]` payloads. The thin glue that pulls fields off Sentry's `Event` and
/// `Breadcrumb` types and feeds them through this scrubber lives in the app and
/// CLI targets where the Sentry SDK is linked, so this type stays testable
/// without launching the app or linking Sentry.
///
/// What it redacts, in priority order on every string:
/// - **Tokens / secrets** — `Bearer …`, `sk-…` style API keys, JWTs, `token=…`
///   / `password=…` assignments, AWS access key IDs.
/// - **Emails** — `user@example.com → <redacted-email>`.
/// - **Home / user paths** — both the injected home directory and any
///   `/Users/<name>/` (and `/home/<name>/`) prefix become a redacted-user
///   equivalent, so the local username never leaks. The generic `/Users/<name>/`
///   rule is what protects build-machine stack-frame paths, whose home dir does
///   not match the user's runtime ``NSHomeDirectory()``.
///
/// It deliberately does **not** touch grouping-relevant fields (exception
/// `type`, fingerprint, frame `function` / `module` / `lineNumber`): the glue
/// only routes path/PII/secret-bearing fields through this scrubber.
///
/// ```swift
/// let scrubber = SentryScrubber()
/// scrubber.scrub("opening /Users/alice/dev/secret with token=sk-abc123def456ghij")
/// // → "opening /Users/<redacted>/dev/secret with token=<redacted-secret>"
/// ```
public struct SentryScrubber: Sendable {
    /// The placeholder substituted for the redacted home directory leaf.
    public static let redactedUser = "<redacted>"
    /// The placeholder substituted for an email address.
    public static let redactedEmail = "<redacted-email>"
    /// The placeholder substituted for a token / secret / key / bearer / password match.
    public static let redactedSecret = "<redacted-secret>"
    /// The placeholder substituted for a raw `Data` value.
    ///
    /// Sentry has no JSON binary type, so it serializes `NSData` to its hex
    /// description *after* `beforeSend` runs. That hex form would carry whatever
    /// bytes the `Data` holds (e.g. a UTF-8 `token=…`), unreachable by the
    /// string-content rules, so any `Data` the scrubber walks is dropped wholesale.
    public static let redactedData = "<redacted-data>"

    /// Matches `/Users/<name>` (the username component stops at the next path
    /// delimiter, quote, whitespace, or end of string) so the local username is
    /// replaced regardless of the runtime home dir AND whether the path has a
    /// trailing component. An exact `/Users/buildbot` or `file:///Users/alice`
    /// is redacted, not just `/Users/alice/...`.
    static let userHomePrefix = SentryRegexPattern(#"/Users/[^/\s"']+"#)

    /// Matches `/home/<name>` for Linux-style paths that can appear in build-machine stack frames.
    static let linuxHomePrefix = SentryRegexPattern(#"/home/[^/\s"']+"#)

    /// Matches the `userinfo@` authority of a URL (`scheme://user:pass@host`).
    ///
    /// Group 1 keeps the `scheme://` prefix; the `user[:pass]` credentials up to
    /// (and including) the `@` are redacted, the host is preserved. Neither the
    /// assignment-token rule nor the email rule covers a `user:pass@` authority.
    ///
    /// This is cmux's equivalent of relay's `@common` `@urlauth` rule
    /// (getsentry/relay @ 99c91d92845fe436713b51018a7f8d2b7b469be5,
    /// relay-pii/src/regexes.rs:319-326). It is kept here, applied first in
    /// ``scrub(_:)`` via `redactURLCredentials`, rather than ported into
    /// ``ScrubberDenylists/valuePatterns`` because cmux's redaction loop treats
    /// group 1 as a prefix to keep (the scheme), the inverse of relay's group-1
    /// convention; duplicating relay's pattern would double-handle with the wrong
    /// group meaning.
    ///
    /// The userinfo class deliberately does **not** exclude `@`, only the
    /// authority terminators (`/`, `?`, `#`, whitespace). A password with an
    /// unencoded `@` (`redis://user:p@ss@host/db`) is therefore consumed
    /// greedily through the *last* `@` of the authority, redacting the whole
    /// credential rather than stopping at the first `@` and leaking the password
    /// tail (`ss@host`). The terminators still bound each match to one URL's
    /// authority, so a later URL's host is never swallowed.
    static let urlUserInfo = SentryRegexPattern(#"([A-Za-z][A-Za-z0-9+.\-]*://)[^/?#\s]+@"#)

    /// Matches an email address.
    static let email = SentryRegexPattern(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)

    /// Matches one query-string segment (a `key=value` or bare `key` between
    /// `&`/`;` separators). Used by ``scrubQueryString(_:)`` so the separators are
    /// never inside a match and survive reassembly verbatim, including empty
    /// segments from runs like `a=1&&b=2`.
    static let queryStringSegment = SentryRegexPattern(#"[^&;]+"#)

    /// The ordered secret / token / key / PEM / financial value patterns.
    ///
    /// Sourced from ``ScrubberDenylists/valuePatterns`` so the maintained relay
    /// `@common` ports and cmux's own provider-key / JWT / AWS rules live in one
    /// provenance-pinned place. Patterns that capture a field prefix in group 1
    /// (e.g. `token=`) keep that prefix in the output; patterns with no capture
    /// group replace the whole match.
    static let secretPatterns: [SentryRegexPattern] = ScrubberDenylists.valuePatterns

    /// The absolute home directory whose prefix is replaced wherever it appears.
    private let homeDirectory: String

    /// A compiled, path-component-bounded pattern for the exact ``homeDirectory``.
    ///
    /// `nil` when ``homeDirectory`` is empty or `/` (nothing meaningful to
    /// redact). Otherwise it matches the literal home path only when it is
    /// followed by a path delimiter, quote, whitespace, or end of string, via a
    /// zero-width `(?=[/\s"']|$)` lookahead. This bounds the replacement to a full
    /// path component so a home dir like `/Users/al` cannot corrupt an unrelated
    /// longer path (`/Users/alice/x`), which an unbounded substring replace would
    /// turn into `/Users/<redacted>ice/x`, leaking the `ice` suffix.
    private let homeDirectoryPattern: SentryRegexPattern?

    /// Creates a scrubber bound to a home directory.
    ///
    /// The default reads the current process home. Tests inject a fixed value so
    /// the scrubber never depends on the developer's real home. The generic
    /// `/Users/<name>/` rule redacts any username independent of this value, so
    /// build-machine stack-frame paths (whose home differs from the runtime one)
    /// are still covered.
    ///
    /// - Parameter homeDirectory: Absolute path replaced wherever it is found. Defaults to ``NSHomeDirectory()``.
    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
        if homeDirectory.isEmpty || homeDirectory == "/" {
            self.homeDirectoryPattern = nil
        } else {
            // Escape the home path so any regex metacharacter in a username is
            // literal, then bound the match to a full path component.
            self.homeDirectoryPattern = SentryRegexPattern(
                NSRegularExpression.escapedPattern(for: homeDirectory) + #"(?=[/\s"']|$)"#
            )
        }
    }

    /// Returns a copy of `text` with secrets, emails, and home/user paths redacted.
    ///
    /// Redaction order is secrets → emails → paths so a token embedded in a path
    /// or after an email is still caught. Returns the input unchanged when it
    /// contains nothing sensitive.
    ///
    /// This is the **unstructured / free-text** path, used for genuinely
    /// free-form fields (an exception value, a log message). It is irreducibly
    /// best-effort: a secret that matches none of the value patterns and is not a
    /// `key=value` assignment, an email, or a path can survive. The real
    /// protections are the field-**selection** allowlist in the glue (only known
    /// safe fields are emitted) and, for *structured* fields, key-aware redaction:
    /// dictionaries go through ``scrub(dictionary:)`` and query strings through
    /// ``scrubQueryString(_:)``, both keyed off the single maintained denylist.
    /// Do not try to make this free-text path exhaustive by widening its regexes;
    /// route structured data through the structured methods instead.
    ///
    /// - Parameter text: The string to scrub.
    /// - Returns: The scrubbed string.
    public func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        result = redactURLCredentials(in: result)
        result = redactSecrets(in: result)
        result = redactEmails(in: result)
        result = redactPaths(in: result)
        return result
    }

    /// Replaces `user:password@` URL credentials with ``redactedSecret``,
    /// preserving the `scheme://` and the host. Runs FIRST so it captures the
    /// whole `user:pass@host` authority before the email rule could match
    /// `pass@host.tld` (which would leak the username); its `>`-terminated
    /// placeholder (`<redacted-secret>@host`) is then immune to the email rule.
    private func redactURLCredentials(in text: String) -> String {
        Self.urlUserInfo.replace(in: text) { match in
            if let scheme = match.captureGroup(1) {
                return "\(scheme)\(Self.redactedSecret)@"
            }
            return "\(Self.redactedSecret)@"
        }
    }

    /// Returns `text` scrubbed, or `nil` when the input is `nil`.
    ///
    /// - Parameter text: The optional string to scrub.
    /// - Returns: The scrubbed string, or `nil`.
    public func scrub(optional text: String?) -> String? {
        guard let text else { return nil }
        return scrub(text)
    }

    /// Recursively scrubs every string found inside a JSON-like value tree.
    ///
    /// Strings are scrubbed; dictionaries and arrays are walked; safe scalars
    /// (`NSNumber`/`Bool`/`Int`/`Double`, `Date`, `Data`, `NSNull`) pass through
    /// untouched. Any other object (notably `URL` / `NSURL`, which carry a file
    /// path) is converted to its string form and scrubbed, because Sentry
    /// serializes unsupported Foundation objects to their description *after*
    /// `beforeSend` runs, which would otherwise leak the unscrubbed path.
    ///
    /// - Parameter value: A `String`, `[String: Any]`, `[Any]`, or scalar.
    /// - Returns: The value with all nested strings scrubbed.
    public func scrub(value: Any) -> Any {
        switch value {
        case let string as String:
            return scrub(string)
        case let dictionary as [String: Any]:
            return scrub(dictionary: dictionary)
        case let array as [Any]:
            return array.map { scrub(value: $0) }
        case is NSNumber, is Date, is NSNull:
            // Safe scalars Sentry serializes faithfully; no string content.
            return value
        case is Data:
            // Sentry stringifies NSData to its hex description after beforeSend,
            // which would leak the bytes (e.g. a UTF-8 token). Drop it wholesale.
            return Self.redactedData
        case let url as URL:
            return scrub(url.absoluteString)
        case let url as NSURL:
            return scrub((url.absoluteString ?? url.description))
        default:
            // Unknown objects are serialized to their description by Sentry, so
            // scrub that string form rather than letting it pass through.
            return scrub(String(describing: value))
        }
    }

    /// Recursively scrubs every value inside a dictionary, treating sensitive
    /// keys as a redaction boundary.
    ///
    /// Values keyed by a sensitive name (``isSensitiveKey(_:)`` — token,
    /// password, secret, api key, authorization, cookie, …) are redacted
    /// wholesale **regardless of shape** (string, array, or nested dictionary),
    /// because the key is the trust boundary and such values (a session id, a
    /// base64 credential, a list of cookies) often do not match any standalone
    /// secret value pattern. All other values are scrubbed by content, recursing
    /// into nested dictionaries and arrays.
    ///
    /// - Parameter dictionary: The dictionary whose values are scrubbed.
    /// - Returns: A new dictionary with the same keys and scrubbed values.
    public func scrub(dictionary: [String: Any]) -> [String: Any] {
        var output = [String: Any](minimumCapacity: dictionary.count)
        for (key, value) in dictionary {
            if Self.isSensitiveKey(key) {
                output[key] = Self.redactedSecret
            } else {
                output[key] = scrub(value: value)
            }
        }
        return output
    }

    /// Recursively scrubs Sentry's two-level `context` map, treating the outer
    /// context name as a redaction boundary.
    ///
    /// Sentry's `event.context` is a `[contextName: [key: value]]` map (the
    /// per-context dictionaries set via `scope.setContext(value:key:)`). This
    /// applies the same key-as-trust-boundary rule as ``scrub(dictionary:)`` but
    /// at the **outer** level too: a context whose NAME is sensitive (e.g.
    /// `credentials`, `auth`) is redacted wholesale, so an inner value that
    /// matches no standalone secret pattern still can't leak. Non-sensitive
    /// contexts recurse through ``scrub(dictionary:)`` so their inner keys and
    /// values are still scrubbed.
    ///
    /// - Parameter context: The `[contextName: [key: value]]` context map.
    /// - Returns: The context map with sensitive contexts redacted and the rest content-scrubbed.
    public func scrub(context: [String: [String: Any]]) -> [String: [String: Any]] {
        var output = [String: [String: Any]](minimumCapacity: context.count)
        for (name, inner) in context {
            if Self.isSensitiveKey(name) {
                // The outer context name is the trust boundary: redact every inner
                // value wholesale rather than recursing.
                output[name] = inner.mapValues { _ -> Any in Self.redactedSecret }
            } else {
                output[name] = scrub(dictionary: inner)
            }
        }
        return output
    }

    /// Redacts the values of sensitive parameters in a URL query string,
    /// structurally, keyed off the single maintained denylist.
    ///
    /// A query string is structured key-value data, so it is redacted by
    /// **parsing** rather than by free-text regex matching: the string is split on
    /// `&` and `;` separators, each `key=value` (or bare `key`) segment is parsed,
    /// and the value is replaced with ``redactedSecret`` whenever
    /// ``isSensitiveKey(_:)`` (the maintained denylist) deems the key sensitive.
    /// The original key text, the `=`, and the original separators are all
    /// preserved; non-sensitive segments pass through untouched.
    ///
    /// This makes ``isSensitiveKey(_:)`` the single source of truth for query
    /// strings: adding a denylist key now covers query params automatically, with
    /// no parallel free-text marker list to drift out of sync. The denylist's
    /// EXACT-match aliases (`csrf`, `_csrf`, `xsrf`, `_vercel_jwt`, `su`,
    /// `sentrysid`, `phpsessid`, `sid`, …) are therefore caught here even though
    /// they are too short to embed safely in the free-text assignment regex.
    ///
    /// The key is URL-decoded before the sensitivity check (so `%5Fcsrf` matches
    /// `_csrf`) but the original, still-encoded key text is emitted unchanged.
    /// Values are matched after the **first** `=` only, so a value that itself
    /// contains `=` (`token=a=b`, base64 padding `==`) or a URL
    /// (`next=https://host/p?token=x`) is not mis-split.
    ///
    /// - Parameter query: The raw query string (without a leading `?`).
    /// - Returns: The query string with sensitive parameter values redacted.
    public func scrubQueryString(_ query: String) -> String {
        guard !query.isEmpty else { return query }
        return Self.queryStringSegment.replace(in: query) { match in
            scrubQueryPair(match.value)
        }
    }

    /// Redacts the value of a single `key=value` query segment when its key is
    /// sensitive, preserving the original key text and `=`.
    ///
    /// A bare `key` (no `=`) and a non-sensitive `key=value` pass through
    /// unchanged. The value is everything after the first `=`, so values that
    /// contain `=` are preserved intact.
    ///
    /// - Parameter segment: One query segment (the text between `&`/`;` separators).
    /// - Returns: The segment with its value redacted when the key is sensitive.
    private func scrubQueryPair(_ segment: String) -> String {
        guard let equalsIndex = segment.firstIndex(of: "=") else {
            // Bare key with no value (`?flag`); nothing to redact.
            return segment
        }
        let key = String(segment[segment.startIndex..<equalsIndex])
        let decodedKey = key.removingPercentEncoding ?? key
        guard Self.isSensitiveKey(decodedKey) else { return segment }
        return "\(key)=\(Self.redactedSecret)"
    }

    /// Returns whether a dictionary/header key names a secret-bearing value.
    ///
    /// Matches common credential field names (case-insensitively, ignoring
    /// `-`/`_` separators) such as `token`, `password`, `secret`, `apiKey`,
    /// `authorization`, and `cookie`.
    ///
    /// - Parameter key: The dictionary or header key.
    /// - Returns: `true` when the key's value should be redacted wholesale.
    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        if sensitiveKeyExactMarkers.contains(normalized) {
            return true
        }
        for marker in sensitiveKeyMarkers where normalized.contains(marker) {
            return true
        }
        return false
    }

    /// Substrings that mark a dictionary/header key as secret-bearing.
    ///
    /// Sourced from ``ScrubberDenylists/sensitiveKeyMarkers`` (ported from
    /// sentry-python `DEFAULT_DENYLIST`). cmux's substring-contains semantics
    /// (vs. sentry-python's exact match) make each marker catch longer
    /// identifiers like `AWS_SECRET_ACCESS_KEY` or `sessionid`.
    static let sensitiveKeyMarkers: [String] = ScrubberDenylists.sensitiveKeyMarkers

    /// Short or marker-free credential key aliases matched WHOLE (not as
    /// substrings), so they don't redact innocuous keys that merely contain them
    /// (e.g. `sid` must not match `inside`/`aside`). The free-text scrubber
    /// covers their `key=value` form via a `\b`-anchored pattern.
    ///
    /// Sourced from ``ScrubberDenylists/sensitiveKeyExactMarkers`` (ported from
    /// sentry-python `DEFAULT_DENYLIST` + `DEFAULT_PII_DENYLIST` and relay's
    /// sensitive-cookie list). Entries are pre-normalized to match against the
    /// normalized key.
    static let sensitiveKeyExactMarkers: Set<String> = ScrubberDenylists.sensitiveKeyExactMarkers

    // MARK: - Paths

    /// Replaces the injected home directory and any `/Users/<name>/` or
    /// `/home/<name>/` prefix with a redacted-user equivalent.
    private func redactPaths(in text: String) -> String {
        var result = text
        if let homeDirectoryPattern {
            // Component-bounded replace (not a raw substring replace), so a home
            // dir that is a prefix of a longer username (`/Users/al` vs.
            // `/Users/alice/x`) never corrupts the longer path and leaks its tail.
            let redacted = Self.redactedHomePath(for: homeDirectory)
            result = homeDirectoryPattern.replace(in: result) { _ in redacted }
        }
        result = Self.userHomePrefix.replace(in: result) { _ in "/Users/\(Self.redactedUser)" }
        result = Self.linuxHomePrefix.replace(in: result) { _ in "/home/\(Self.redactedUser)" }
        return result
    }

    /// Returns the redacted form of an absolute home directory.
    ///
    /// Replaces the trailing user component of a `/Users/<name>` or
    /// `/home/<name>` home path with `<redacted>`, preserving the rest of the
    /// path shape. Paths that do not fit that shape are replaced wholesale.
    ///
    /// - Parameter homeDirectory: The absolute home directory path.
    /// - Returns: The path with its user component redacted.
    static func redactedHomePath(for homeDirectory: String) -> String {
        let components = homeDirectory.split(separator: "/", omittingEmptySubsequences: false)
        // ["", "Users", "alice"] for "/Users/alice"
        if components.count >= 3, components[1] == "Users" || components[1] == "home" {
            return "/\(components[1])/\(redactedUser)"
        }
        return "/\(redactedUser)"
    }

    // MARK: - Emails

    /// Replaces email addresses with ``redactedEmail``.
    private func redactEmails(in text: String) -> String {
        Self.email.replace(in: text) { _ in Self.redactedEmail }
    }

    // MARK: - Secrets

    /// Replaces token / secret / key / bearer / password patterns with ``redactedSecret``.
    private func redactSecrets(in text: String) -> String {
        var result = text
        for pattern in Self.secretPatterns {
            result = pattern.replace(in: result) { match in
                // Patterns with a captured prefix group (e.g. "token=") keep the
                // prefix and redact only the value, so the field stays legible.
                if let prefix = match.captureGroup(1) {
                    return "\(prefix)\(Self.redactedSecret)"
                }
                return Self.redactedSecret
            }
        }
        return result
    }
}
