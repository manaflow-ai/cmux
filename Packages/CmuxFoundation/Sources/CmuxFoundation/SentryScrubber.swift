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
    static let urlUserInfo = SentryRegexPattern(#"([A-Za-z][A-Za-z0-9+.\-]*://)[^/?#@\s]+@"#)

    /// Matches an email address.
    static let email = SentryRegexPattern(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)

    /// The ordered secret / token / key / bearer / password patterns.
    ///
    /// Patterns that capture a field prefix in group 1 (e.g. `token=`) keep that
    /// prefix in the output so the redacted field stays legible; patterns with no
    /// capture group replace the whole match.
    static let secretPatterns: [SentryRegexPattern] = [
        // Bearer <token>
        SentryRegexPattern(#"(Bearer\s+)[A-Za-z0-9\-._~+/]+=*"#),
        // Authorization: <scheme> <token>  (Basic / Digest / token / etc.)
        SentryRegexPattern(#"(Authorization:\s*\w+\s+)\S+"#),
        // `<sensitive-key> = value` in raw query strings, env-style assignments,
        // or JSON ("key":"value"). The marker set is kept in sync with the
        // key-aware dictionary path (``isSensitiveKey(_:)``) so a credential like
        // `auth=…`, `session_id=…`, or `cookie=…` is redacted whether it arrives
        // as a dictionary entry or as raw text. The marker may be embedded in a
        // longer identifier (e.g. AWS_SECRET_ACCESS_KEY, MY_API_KEY), so optional
        // identifier characters are allowed around it.
        SentryRegexPattern(
            #"([A-Za-z0-9.\-]*(?:access[_\-]?token|api[_\-]?key|access[_\-]?key|private[_\-]?key|session[_\-]?id|session|secret|token|password|passwd|pwd|credentials?|cookie|bearer|auth)[A-Za-z0-9.\-]*["']?\s*[:=]\s*["']?)[^\s"'&,}]+"#
        ),
        // The bare `sid` session alias (`?sid=…`, `&sid=…`, `sid:…`) carries a
        // session credential but is too short to embed in the marker set above
        // without matching innocuous substrings (`inside=`, `aside=`). A `\b`
        // word boundary anchors it so only a standalone `sid` key is redacted.
        SentryRegexPattern(#"(\bsid["']?\s*[:=]\s*["']?)[^\s"'&,}]+"#),
        // Provider-style keys: sk-..., pk-..., ghp_..., xoxb-..., and similar prefixes.
        SentryRegexPattern(#"\b(?:sk|pk|rk|ghp|gho|ghu|ghs|ghr|xox[baprs])[_\-][A-Za-z0-9_\-]{16,}"#),
        // JSON Web Tokens: three base64url segments separated by dots.
        SentryRegexPattern(
            #"\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#,
            options: []
        ),
        // AWS access key IDs.
        SentryRegexPattern(#"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#, options: []),
    ]

    /// The absolute home directory whose prefix is replaced wherever it appears.
    private let homeDirectory: String

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
    }

    /// Returns a copy of `text` with secrets, emails, and home/user paths redacted.
    ///
    /// Redaction order is secrets → emails → paths so a token embedded in a path
    /// or after an email is still caught. Returns the input unchanged when it
    /// contains nothing sensitive.
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
    static let sensitiveKeyMarkers: [String] = [
        "password",
        "passwd",
        "secret",
        "token",
        "apikey",
        "accesskey",
        "authorization",
        "auth",
        "cookie",
        "credential",
        "bearer",
        "session",
        "privatekey",
    ]

    /// Short credential key aliases matched WHOLE (not as substrings), so they
    /// don't redact innocuous keys that merely contain them (e.g. `sid` must not
    /// match `inside`/`aside`). The free-text scrubber covers their `key=value`
    /// form via a `\b`-anchored pattern.
    static let sensitiveKeyExactMarkers: Set<String> = ["sid"]

    // MARK: - Paths

    /// Replaces the injected home directory and any `/Users/<name>/` or
    /// `/home/<name>/` prefix with a redacted-user equivalent.
    private func redactPaths(in text: String) -> String {
        var result = text
        if !homeDirectory.isEmpty, homeDirectory != "/" {
            result = result.replacingOccurrences(of: homeDirectory, with: Self.redactedHomePath(for: homeDirectory))
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
