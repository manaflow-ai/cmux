import Foundation

/// A URL that came from a page or a tab (a tab's address, a frame's, a
/// request's, a download's, a navigation that was cancelled, a popup's),
/// not from the session that reads it.
///
/// Such a URL can carry a credential (a sign-in link's `code`, a signed
/// download's `X-Amz-Signature`, a `user:password@`). The tab's live
/// creator navigated the tab and holds those values already; every other
/// reader gets ``credentialFree``. A driver puts this type, never the
/// string, in a result or an event payload, and ``BrowserReplDriverOutput``
/// turns it into the reader's string where output leaves the driver.
public struct BrowserReplPageURL: Sendable, Equatable {
    /// The live session that created the tab, the only reader that gets
    /// the URL as written. `nil` when no reader does: a user's tab, a
    /// history entry (the user and every session share the history), a
    /// frame the creator's own domain policy blocks.
    public let creator: String?
    private let raw: String

    public init(_ raw: String, creator: String?) {
        self.raw = raw
        self.creator = creator
    }

    /// The URL with its credential values replaced
    /// (``Swift/String/redactingBrowserReplURLCredentials()``).
    public var credentialFree: String { raw.redactingBrowserReplURLCredentials() }

    /// The URL as `reader` may read it.
    public func string(for reader: String) -> String {
        reader == creator ? raw : credentialFree
    }

    /// The URL as written and as `reader` gets it, when they differ.
    fileprivate func replacement(for reader: String) -> (raw: String, shown: String)? {
        let shown = string(for: reader)
        return shown == raw || raw.isEmpty ? nil : (raw, shown)
    }
}

/// A request's or a response's headers, from a page's network traffic.
/// The tab's live creator gets them as sent; every other reader gets them
/// without the credential headers (``Swift/Dictionary/removingBrowserReplCredentialHeaders()``)
/// and with the credential values in the URL-valued ones it keeps replaced.
public struct BrowserReplPageHeaders: Sendable, Equatable {
    /// As ``BrowserReplPageURL/creator``.
    public let creator: String?
    private let raw: [String: String]

    public init(_ raw: [String: String], creator: String?) {
        self.raw = raw
        self.creator = creator
    }

    /// The headers as `reader` may read them.
    public func headers(for reader: String) -> [String: String] {
        guard reader != creator else { return raw }
        var kept = raw.removingBrowserReplCredentialHeaders()
        for (name, value) in kept where Self.urlValuedHeaderNames.contains(name.lowercased()) {
            kept[name] = value.redactingBrowserReplURLCredentials()
        }
        return kept
    }

    /// Headers whose value is, or holds, a URL.
    static var urlValuedHeaderNames: Set<String> {
        ["location", "content-location", "referer", "refresh", "link"]
    }
}

/// Where a driver's results and event payloads leave the driver for one
/// session (`reader`): each ``BrowserReplPageURL`` and
/// ``BrowserReplPageHeaders`` becomes the reader's form, and when the
/// reader gets a URL without its credential values, every other string of
/// the same payload that repeats the URL as written (a refusal's reason,
/// say) gets the reader's form too.
///
/// Nothing is masked here. The session masks every value it holds, the
/// values other sessions typed and the TOTP codes in one pass over the
/// original JSON at its egress gate (``BrowserReplBoundary/egress(_:)``):
/// masking some of them here first would let a value another session
/// typed replace the start of one of the session's own secrets before
/// that pass looks for it, and the rest of the secret would leak.
public struct BrowserReplDriverOutput: Sendable {
    /// The session that reads.
    public let reader: String

    public init(reader: String) {
        self.reader = reader
    }

    /// A driver result as JSON text; `nil` when it is not JSON.
    public func result(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return "null" }
        return JSONSerialization.browserReplString(resolve(value))
    }

    /// An event payload as JSON text; `nil` when it is not JSON.
    ///
    /// Every event's `url` is a page's or a tab's, so one a driver left a
    /// plain string is taken as a page URL no reader gets as written: only
    /// a ``BrowserReplPageURL`` naming the reader as the tab's creator
    /// reaches it with its credentials.
    public func event(_ payload: [String: Any]) -> String? {
        var payload = payload
        if let url = payload["url"] as? String { payload["url"] = BrowserReplPageURL(url, creator: nil) }
        return JSONSerialization.browserReplString(resolve(payload))
    }

    /// `value` with every page URL and header set in the reader's form.
    func resolve(_ value: Any) -> Any {
        var replacements: [(raw: String, shown: String)] = []
        let resolved = resolve(value, replacements: &replacements)
        guard !replacements.isEmpty else { return resolved }
        // The longest first, so a URL that extends another is replaced whole.
        replacements.sort { $0.raw.utf8.count > $1.raw.utf8.count }
        return Self.replacing(resolved, replacements)
    }

    private func resolve(_ value: Any, replacements: inout [(raw: String, shown: String)]) -> Any {
        switch value {
        case let url as BrowserReplPageURL:
            if let replacement = url.replacement(for: reader) { replacements.append(replacement) }
            return url.string(for: reader)
        case let headers as BrowserReplPageHeaders:
            return headers.headers(for: reader)
        case let list as [Any]:
            return list.map { resolve($0, replacements: &replacements) }
        case let object as [String: Any]:
            return object.mapValues { resolve($0, replacements: &replacements) }
        default:
            return value
        }
    }

    private static func replacing(_ value: Any, _ replacements: [(raw: String, shown: String)]) -> Any {
        switch value {
        case let text as String:
            var text = text
            for replacement in replacements where text.contains(replacement.raw) {
                text = text.replacingOccurrences(of: replacement.raw, with: replacement.shown)
            }
            return text
        case let list as [Any]:
            return list.map { replacing($0, replacements) }
        case let object as [String: Any]:
            return object.mapValues { replacing($0, replacements) }
        default:
            return value
        }
    }
}
