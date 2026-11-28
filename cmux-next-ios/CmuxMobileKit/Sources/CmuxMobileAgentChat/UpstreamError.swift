import Foundation

/// One reading of an upstream model error, the same as the Mac's
/// (`cmux-tui/crates/cmux-upstream-error`, cmux#58405): whether the provider had no capacity, whether
/// an account's own rate limit refused the request, and the wait the text names.
///
/// Before this, the phone read the same refusal its own way: `TurnFailureCopy` knew no "at its call
/// limit" (the worker gateway's 502) and `ChiefTurnFailure` took any "529" in the text, "id 5290" too,
/// as busy (ask-616b73f6bc, "fix 529s properly with better designs"). What an error *says* is decided
/// here; each caller keeps its own policy (which sentence, which kind).
public enum UpstreamError {
    /// Whether `code` (three digits) is in `message` as a number of its own: "HTTP 503", not "2503s".
    public static func hasStatus(_ message: String, _ code: String) -> Bool {
        let bytes = Array(message.utf8)
        let needle = Array(code.utf8)
        guard !needle.isEmpty, bytes.count >= needle.count else { return false }
        func alphanumeric(_ byte: UInt8) -> Bool {
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        }
        for at in 0...(bytes.count - needle.count) where bytes[at..<(at + needle.count)].elementsEqual(needle) {
            let before = at > 0 ? bytes[at - 1] : nil
            let after = at + needle.count < bytes.count ? bytes[at + needle.count] : nil
            if !(before.map(alphanumeric) ?? false), !(after.map(alphanumeric) ?? false) { return true }
        }
        return false
    }

    /// Whether the provider or the gateway had no capacity for the request a moment ago, whichever account
    /// asked: HTTP 503 or 529, `overloaded_error`, "at capacity" (Codex), the SR2 gateway's "no
    /// non-exhausted ... accounts", the worker gateway's "at its call limit". An account's own rate limit
    /// (429) is not: it is ``isAccountLimit(_:)``.
    public static func isCapacity(_ message: String) -> Bool {
        let m = message.lowercased()
        return hasStatus(m, "503")
            || hasStatus(m, "529")
            || m.contains("overloaded")
            || m.contains("at capacity")
            || m.contains("no non-exhausted")
            // The cmux-platform worker gateway's own ceiling: "502 the gateway is at its call limit; retry".
            || m.contains("at its call limit")
    }

    /// Whether an account's own rate limit refused the request (HTTP 429, "rate limit", "too many requests").
    public static func isAccountLimit(_ message: String) -> Bool {
        let m = message.lowercased()
        return hasStatus(m, "429")
            || m.contains("rate limit")
            || m.contains("rate_limit")
            || m.contains("too many requests")
    }

    /// The wait an error's text names, in seconds, in any of the forms our upstreams print: "retry after
    /// 3596s" (the subrouter), "retry-after: 30" (a header copied into the message), "retry-after 30",
    /// `"retry_after":30` or `"retry-after":"30"` (a JSON body).
    public static func retryAfter(_ message: String) -> Int? {
        let lower = message.lowercased()
        let leads = ["retry after ", "retry-after: ", "retry-after ", "\"retry_after\":", "\"retry-after\":", "\"retry_after_s\":"]
        for lead in leads {
            // The first occurrence of the lead, as Rust's `split_once`; a lead with no number falls to the next.
            guard let range = lower.range(of: lead) else { continue }
            let rest = lower[range.upperBound...].drop(while: { $0 == " " || $0 == "\"" })
            let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
            if let seconds = Int(digits) { return seconds }
        }
        return nil
    }
}
