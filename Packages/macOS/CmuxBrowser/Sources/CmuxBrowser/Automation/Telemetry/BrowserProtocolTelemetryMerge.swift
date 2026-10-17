import Foundation

/// Merges a Chromium page's protocol logs with the JavaScript bootstrap's
/// (`window.__cmuxConsoleLog`, `window.__cmuxErrorLog`) without duplicates.
///
/// Once recording runs, the protocol saw every message of the document:
/// `Runtime.enable` replays the messages logged before it, and it also sees
/// frames and calls the main-frame bootstrap does not. A bootstrap entry is
/// kept only when it is older than the recording and no protocol entry
/// matches it (a replay the engine dropped); everything else comes from the
/// protocol. Without recording the bootstrap's entries are returned as is.
public enum BrowserProtocolTelemetryMerge {
    /// `browser.console.list` items, oldest first.
    public static func consoleItems(
        protocolEntries: [BrowserProtocolConsoleEntry],
        scriptItems: [[String: Any]],
        recordingStartedAtMS: Double?
    ) -> [[String: Any]] {
        guard let start = recordingStartedAtMS else { return scriptItems }
        var unmatched = protocolEntries.map { "\(normalizedLevel($0.level))\u{0}\($0.text)" }
        var merged = protocolEntries.map { (time: $0.timestampMS, item: $0.jsonObject) }
        for item in scriptItems {
            let level = normalizedLevel(item["level"] as? String ?? "log")
            let key = "\(level)\u{0}\(item["text"] as? String ?? "")"
            if let index = unmatched.firstIndex(of: key) {
                unmatched.remove(at: index)
                continue
            }
            guard let time = timestamp(item), time < start else { continue }
            merged.append((time, item))
        }
        return ordered(merged)
    }

    /// `browser.errors.list` items, oldest first. The bootstrap writes an
    /// unhandled rejection's bare reason; the protocol prefixes it
    /// (`Uncaught (in promise) ...`), so a protocol message containing the
    /// bootstrap's matches it.
    public static func errorItems(
        protocolErrors: [BrowserProtocolPageError],
        scriptItems: [[String: Any]],
        recordingStartedAtMS: Double?
    ) -> [[String: Any]] {
        guard let start = recordingStartedAtMS else { return scriptItems }
        var unmatched = protocolErrors.map(\.message)
        var merged = protocolErrors.map { (time: $0.timestampMS, item: $0.jsonObject) }
        for item in scriptItems {
            let message = item["message"] as? String ?? ""
            if let index = unmatched.firstIndex(where: { $0 == message || (!message.isEmpty && $0.contains(message)) }) {
                unmatched.remove(at: index)
                continue
            }
            guard let time = timestamp(item), time < start else { continue }
            merged.append((time, item))
        }
        return ordered(merged)
    }

    private static func normalizedLevel(_ level: String) -> String {
        level == "warning" ? "warn" : level
    }

    private static func timestamp(_ item: [String: Any]) -> Double? {
        (item["timestamp_ms"] as? NSNumber)?.doubleValue
    }

    /// Stable by time.
    private static func ordered(_ items: [(time: Double, item: [String: Any])]) -> [[String: Any]] {
        items.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element.item)
    }
}
