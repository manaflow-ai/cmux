#if DEBUG
import Foundation

/// Redacts sensitive fields out of the browser context-download DEBUG event log
/// before each line reaches the debug sink. The log lines are sequences of
/// `key=value` fields (separated by spaces); fields whose key is `referer`,
/// `path`, `payload`, or ends in `url` carry user data, so their values are
/// replaced with a scheme-only summary or `<redacted>`. The `payload` field is
/// treated as trailing (everything after it is redacted as one value).
///
/// Holds the compiled field-matching `NSRegularExpression` as instance state so
/// the pattern is built once per redactor rather than per call. DEBUG-only: the
/// context-download trace log it serves only exists in debug builds.
public struct BrowserContextDownloadLogRedactor {
    private let fieldPattern: NSRegularExpression

    public init() {
        fieldPattern = try! NSRegularExpression(
            pattern: "(^| )([A-Za-z][A-Za-z0-9_-]*)=",
            options: []
        )
    }

    /// Returns `message` with the values of sensitive `key=value` fields redacted.
    /// Non-sensitive fields and any surrounding text are preserved verbatim.
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

    private func shouldRedactField(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized == "referer" ||
            normalized == "path" ||
            normalized == "payload" ||
            normalized.hasSuffix("url")
    }

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

    private func shouldTreatFieldAsURL(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized == "referer" || normalized.hasSuffix("url")
    }
}
#endif
