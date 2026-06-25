#if DEBUG
import Foundation

/// Redacts sensitive `field=value` tokens out of the browser context-download
/// debug-log markers before they reach the `#if DEBUG` `cmuxDebugLog` sink.
///
/// Lifted byte-faithfully out of the app-target `CmuxWebView` so the
/// debug-trace scrubbing that protects referers, paths, payloads, and any
/// `*url` field lives in `CmuxBrowser` beside the rest of the download cluster
/// (`BrowserDownloadURLClassifier`, `BrowserDataURLPayload`). The whole file is
/// `#if DEBUG`-gated because the markers it scrubs only exist in DEBUG builds;
/// production logging never routes through here.
///
/// The compiled `field=value` scanning regex and the lowercased sensitive-field
/// rule set are the only state, held as stored value properties, so this is a
/// real instance value type, not a static-only namespace of utilities: the app
/// debug sink constructs one `ContextDownloadDebugRedactor()` and calls
/// `redact(_:)` per marker. A pure value type with only `Sendable` stored state,
/// so it is `Sendable` and `nonisolated`. Pure Foundation
/// (`NSString`/`NSRegularExpression`), no instance reference state.
public nonisolated struct ContextDownloadDebugRedactor: Sendable {
    /// Matches a leading-separator + `field=` token (`(^| )([A-Za-z][A-Za-z0-9_-]*)=`)
    /// so values can be located and selectively redacted by field name.
    private let fieldPattern: NSRegularExpression

    /// Lowercased field names whose values are always redacted; `path`,
    /// `payload`, `referer`, and any `*url` suffix.
    private let sensitiveExactFields: Set<String>

    /// Lowercased field-name suffix that marks a value as a URL to be host-only
    /// redacted (`*url`).
    private let urlFieldSuffix: String

    /// Builds a redactor with the default `field=value` scanner and the default
    /// sensitive-field rule set.
    public init() {
        // The pattern is a compile-time constant, so the force-try matches the
        // app-target original exactly; it can never fail at runtime.
        fieldPattern = try! NSRegularExpression(
            pattern: "(^| )([A-Za-z][A-Za-z0-9_-]*)=",
            options: []
        )
        sensitiveExactFields = ["referer", "path", "payload"]
        urlFieldSuffix = "url"
    }

    /// Returns `message` with every sensitive `field=value` token's value
    /// redacted. Non-sensitive tokens and surrounding text pass through
    /// unchanged. When no `field=` token is present the message is returned
    /// verbatim.
    public func redact(_ message: String) -> String {
        let nsMessage = message as NSString
        let fullRange = NSRange(location: 0, length: nsMessage.length)
        let matches = fieldPattern.matches(in: message, range: fullRange)
        guard !matches.isEmpty else { return message }

        var result = ""
        var cursor = 0
        var matchIndex = 0

        while matchIndex < matches.count {
            let match = matches[matchIndex]
            let fieldStart = match.range.location
            if cursor < fieldStart {
                result += nsMessage.substring(
                    with: NSRange(location: cursor, length: fieldStart - cursor)
                )
            }

            let separatorRange = match.range(at: 1)
            if separatorRange.length > 0 {
                result += " "
            }

            let keyRange = match.range(at: 2)
            let key = nsMessage.substring(with: keyRange)
            let valueStart = match.range.location + match.range.length
            let sensitive = shouldRedactField(key)
            let valueEnd: Int

            if sensitive && key.lowercased() == "payload" {
                valueEnd = nsMessage.length
                matchIndex = matches.count
            } else {
                valueEnd = matchIndex + 1 < matches.count
                    ? matches[matchIndex + 1].range.location
                    : nsMessage.length
                matchIndex += 1
            }

            let valueLength = max(0, valueEnd - valueStart)
            let value = nsMessage.substring(with: NSRange(location: valueStart, length: valueLength))

            if sensitive {
                result += "\(key)=\(redactedValue(key: key, value: value))"
            } else {
                result += nsMessage.substring(
                    with: NSRange(location: keyRange.location, length: valueEnd - keyRange.location)
                )
            }

            cursor = valueEnd
        }

        if cursor < nsMessage.length {
            result += nsMessage.substring(
                with: NSRange(location: cursor, length: nsMessage.length - cursor)
            )
        }

        return result
    }

    /// Whether `key`'s value must be redacted (referer / path / payload / `*url`).
    private func shouldRedactField(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return sensitiveExactFields.contains(normalized) ||
            normalized.hasSuffix(urlFieldSuffix)
    }

    /// The redacted form of a sensitive value: host-only for `http`/`https`
    /// URLs, scheme-tagged `<redacted>` for `data`/`file`/other schemes, and a
    /// bare `<redacted>` otherwise. `nil` and empty values pass through.
    private func redactedValue(key: String, value: String) -> String {
        guard value != "nil", !value.isEmpty else { return value }

        if shouldTreatFieldAsURL(key),
           let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           !scheme.isEmpty {
            switch scheme {
            case "http", "https":
                return "\(scheme)://\(url.host ?? "unknown")"
            case "data":
                return "data:<redacted>"
            case "file":
                return "file:<redacted>"
            default:
                return "\(scheme):<redacted>"
            }
        }

        return "<redacted>"
    }

    /// Whether `key`'s value should be parsed as a URL for host-only redaction
    /// (referer / `*url`).
    private func shouldTreatFieldAsURL(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized == "referer" || normalized.hasSuffix(urlFieldSuffix)
    }
}
#endif
