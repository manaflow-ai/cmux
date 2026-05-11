import Foundation

/// Per-terminal-panel companion WebView state.
///
/// Persisted alongside the panel so a sidekick URL survives restarts
/// and follows the session across move-to-new-workspace.
public struct SidekickState: Codable, Hashable, Sendable {
    public var url: URL?
    public var isOpen: Bool
    public var splitRatio: Double   // 0.2 … 0.8, fraction allocated to webview
    public var orientation: Orientation
    public var pinnedURLs: [URL]    // history of URLs detected/visited in session

    public enum Orientation: String, Codable, Sendable { case horizontal, vertical }

    public static let `default` = SidekickState(
        url: nil, isOpen: false, splitRatio: 0.4,
        orientation: .horizontal, pinnedURLs: [])
}

/// Detects URLs in a stream of terminal output.
///
/// Single shared regex; fed by `TerminalSurface` write callbacks
/// (TODO P2). Emits `URLDetected` events through `NotificationCenter`
/// so any open sidekick can offer to load.
public enum SidekickURLDetector {
    private static let pattern: NSRegularExpression = {
        // Conservative URL match: scheme + host + optional path/query.
        try! NSRegularExpression(
            pattern: #"https?://[^\s<>"'\)\]]+"#,
            options: [])
    }()

    public static func extract(from chunk: String) -> [URL] {
        let range = NSRange(chunk.startIndex..., in: chunk)
        return pattern.matches(in: chunk, range: range).compactMap { m in
            guard let r = Range(m.range, in: chunk) else { return nil }
            return URL(string: String(chunk[r]))
        }
    }
}

public extension Notification.Name {
    /// `userInfo`: `["panelID": UUID, "url": URL]`
    static let cmuxSidekickURLDetected = Notification.Name("cmux.sidekick.urlDetected")
    /// `userInfo`: `["panelID": UUID]`
    static let cmuxSidekickToggle = Notification.Name("cmux.sidekick.toggle")
}
