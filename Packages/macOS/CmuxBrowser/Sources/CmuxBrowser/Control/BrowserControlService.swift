import Foundation

/// Stateless browser-control logic shared by the cmux v2 browser RPC methods.
///
/// This is the `Sendable` Service half of the browser-control domain: it owns the
/// pure pieces of `browser` RPC handling that touch neither workspace/pane/surface
/// lifecycle nor any AppKit/WebKit object. Specifically it builds the JavaScript
/// strings for the semantic element locators (`find.role`, `find.text`, and the
/// other `find.*` actions), canonical keyboard events, the not-found diagnostics
/// probe, and the `find.first`/`find.last`/`find.nth` selector scripts; it
/// normalizes raw JavaScript results into JSON-serializable values; it classifies
/// JavaScript failures; and it composes the human-readable element-not-found
/// message.
///
/// The owning `@MainActor` controller keeps the per-surface mutable state
/// (element-ref table, dialog queue, init scripts) and the WebKit evaluation seam;
/// it forwards into this service for the stateless work, so the RPC wire output is
/// byte-for-byte identical to the previous inlined implementation.
public struct BrowserControlService: Sendable {
    /// Envelope constants for the `browser eval` undefined/value distinction.
    public let evalEnvelope: BrowserEvalEnvelope

    /// Creates a browser-control service.
    /// - Parameter evalEnvelope: wire constants for the eval envelope. Defaults to
    ///   the standard cmux v2 values.
    public init(evalEnvelope: BrowserEvalEnvelope = BrowserEvalEnvelope()) {
        self.evalEnvelope = evalEnvelope
    }

    // MARK: - Value helpers

    /// Renders a value as a bare JavaScript literal (no surrounding brackets),
    /// suitable for interpolation into a generated script.
    ///
    /// Serializes the value via `JSONSerialization` wrapped in a one-element array
    /// and strips the array brackets; falls back to a manually escaped string
    /// literal, then to `null`. Byte-identical to the previous `v2JSONLiteral`.
    /// - Parameter value: the value to encode.
    /// - Returns: a JavaScript literal expression.
    public func jsonLiteral(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        if let s = value as? String {
            return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "null"
    }

    /// Recursively converts a raw JavaScript evaluation result into a
    /// JSON-serializable value, re-materializing the `undefined` sentinel into the
    /// eval envelope shape.
    ///
    /// - Parameters:
    ///   - value: the raw value returned by the WebKit evaluator.
    ///   - isUndefinedSentinel: predicate identifying the owner's `undefined`
    ///     sentinel object. The sentinel type lives in the app target, so it is
    ///     injected here as a closure seam.
    /// - Returns: a value safe to hand to `JSONSerialization`.
    public func normalizeJSValue(_ value: Any?, isUndefinedSentinel: (Any) -> Bool) -> Any {
        guard let value else { return NSNull() }
        if isUndefinedSentinel(value) {
            return [
                evalEnvelope.typeKey: evalEnvelope.typeUndefined,
                evalEnvelope.valueKey: NSNull()
            ]
        }
        if value is NSNull { return NSNull() }
        if let v = value as? String { return v }
        if let v = value as? NSNumber { return v }
        if let v = value as? Bool { return v }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = normalizeJSValue(v, isUndefinedSentinel: isUndefinedSentinel)
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { normalizeJSValue($0, isUndefinedSentinel: isUndefinedSentinel) }
        }
        return String(describing: value)
    }

    // MARK: - Failure classification

    /// True when a page-world JavaScript failure looks like a Content Security
    /// Policy block of `eval`/`Function` construction (`script-src` without
    /// `'unsafe-eval'`). Gating the isolated-world retry on this avoids re-running a
    /// script that already failed for an ordinary reason. Byte-identical to the
    /// previous `v2BrowserFailureLooksLikeCSPEvalBlock`.
    /// - Parameter message: the failure message.
    /// - Returns: whether the message indicates a CSP eval block.
    public func failureLooksLikeCSPEvalBlock(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("unsafe-eval")
            || lower.contains("content security policy")
            || lower.contains("blocked by csp")
            || lower.contains("refused to evaluate")
    }

    /// Extracts the real JavaScript exception text from a `WKError`.
    ///
    /// `WKError.localizedDescription` for JS exceptions is the useless generic
    /// "A JavaScript exception occurred"; the real text lives in `userInfo` under
    /// `WKJavaScriptExceptionMessage`, with the line number under
    /// `WKJavaScriptExceptionLineNumber`. Byte-identical to the previous
    /// `v2DescribeJavaScriptError`.
    /// - Parameter error: the error thrown by the evaluator.
    /// - Returns: a human-readable description.
    public func describeJavaScriptError(_ error: any Error) -> String {
        let nsError = error as NSError
        guard let exceptionMessage = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String,
              !exceptionMessage.isEmpty else {
            return error.localizedDescription
        }
        var detail = exceptionMessage
        if let line = nsError.userInfo["WKJavaScriptExceptionLineNumber"] as? Int, line > 0 {
            detail += " (line \(line))"
        }
        return detail
    }

    // MARK: - Not-found message

    /// Composes the human-readable element-not-found message from the match counts
    /// already gathered by the diagnostics probe. Byte-identical to the message
    /// branches previously inlined in `v2BrowserElementNotFoundResult`.
    /// - Parameters:
    ///   - selector: the selector that failed to resolve.
    ///   - matchCount: total DOM matches for the selector.
    ///   - visibleCount: visible matches for the selector.
    /// - Returns: the user-facing not-found message.
    public func elementNotFoundMessage(selector: String, matchCount: Int, visibleCount: Int) -> String {
        if matchCount > 0 && visibleCount == 0 {
            return "Element \"\(selector)\" is present but not visible."
        } else if matchCount > 1 {
            return "Selector \"\(selector)\" matched multiple elements."
        } else {
            return "Element \"\(selector)\" not found or not visible. Run 'browser snapshot' to see current page elements."
        }
    }
}
