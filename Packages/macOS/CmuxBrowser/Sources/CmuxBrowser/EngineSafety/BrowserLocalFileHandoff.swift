public import Foundation

/// Where a Chromium pane hands a local file instead of loading it.
///
/// The cmux CEF fork builds without proprietary codecs, so H.264/HEVC video
/// and AAC audio open in WebKit (which plays them through AVFoundation), and
/// Markdown opens in cmux's Markdown viewer. The CEF shim cancels such a
/// main-frame navigation and reports it (`CEFHandsOffLocalFile`,
/// CEFShim/src/local_file_handoff.h); both copies pass
/// `schemas/local-file-handoff/vectors.json`. WebKit panes in Classic keep
/// loading every local file themselves, so this applies to Chromium only.
public enum BrowserLocalFileHandoff: Equatable, Sendable {
    /// cmux's Markdown viewer.
    case markdownViewer
    /// A WebKit browser pane.
    case webKitPane

    /// Where a Chromium pane hands `url` off, or nil when it loads it itself.
    public static func chromiumHandoff(for url: URL) -> BrowserLocalFileHandoff? {
        guard url.scheme?.lowercased() == "file" else { return nil }
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return .markdownViewer
        case "mp4", "mov", "m4v", "m4a", "aac": return .webKitPane
        default: return nil
        }
    }
}

/// A main-frame navigation to a scheme neither Chromium nor cmux loads
/// (mailto:, tel:, an app's own scheme). The CEF shim cancels it before it
/// starts and reports it, so the pane routes it through the same external-app
/// handling a WebKit pane uses instead of committing Chromium's
/// ERR_UNKNOWN_URL_SCHEME page. Swift copy of `IsExternalAppURL`
/// (CEFShim/src/external_url.h). `web+` and `ext+` schemes stay Chromium's.
extension String {
    /// True for URL text a Chromium pane hands to another app instead of
    /// loading (see above).
    public var isChromiumExternalAppURL: Bool {
        // Bytes, as the C++ copy reads them: a grapheme search would miss a
        // `:` followed by a combining mark.
        let bytes = Array(utf8)
        guard let colon = bytes.firstIndex(of: 0x3A), colon != 0 else { return false }
        let scheme = String(decoding: bytes[..<colon].map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
        if Self.chromiumLoadedSchemes.contains(scheme) { return false }
        return !scheme.hasPrefix("web+") && !scheme.hasPrefix("ext+")
    }

    private static let chromiumLoadedSchemes: Set<String> = [
        "http", "https", "ws", "wss", "file", "about", "data", "blob", "filesystem", "javascript",
        "chrome", "chrome-extension", "chrome-untrusted", "chrome-search", "chrome-error", "chrome-native",
        "devtools", "view-source", "isolated-app", "cmux-page",
    ]
}
