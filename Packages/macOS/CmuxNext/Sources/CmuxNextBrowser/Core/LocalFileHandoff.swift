public import Foundation

/// A local file a browser tab hands to cmux's file opener instead of loading:
/// Markdown opens the markdown page, and the video and audio the Chromium build
/// cannot decode (H.264/HEVC and AAC; the fork builds without proprietary
/// codecs, plans/cmux-next/browser.md) open in a WebKit tab, which plays them
/// through AVFoundation. A CEF tab hands both off (the shim cancels the
/// navigation and reports `localFileHandoff`); a WebKit tab hands off Markdown
/// only. The C++ copy is the shim's `CEFHandsOffLocalFile`
/// (CEFShim/src/local_file_handoff.h); both pass
/// schemas/local-file-handoff/vectors.json.
public nonisolated enum LocalFileHandoff {
    public enum Target: Equatable, Sendable {
        /// cmux's markdown page.
        case markdownPage
        /// A WebKit browser tab.
        case webKitTab
    }

    public static let markdownExtensions: Set<String> = ["md", "markdown"]
    /// Video and audio a CEF tab cannot play: H.264/HEVC video, AAC audio.
    public static let webKitMediaExtensions: Set<String> = ["mp4", "mov", "m4v", "m4a", "aac"]

    /// Where the local file at `url` shows, nil for any other URL or a file a
    /// browser tab shows itself.
    public static func target(for url: URL) -> Target? {
        guard url.scheme?.lowercased() == "file" else { return nil }
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdownPage }
        if webKitMediaExtensions.contains(ext) { return .webKitTab }
        return nil
    }

    /// Whether a tab of `engine` hands a main-frame navigation to `url` off.
    public static func handsOff(_ url: URL, engine: BrowserEngineKind) -> Bool {
        switch target(for: url) {
        case .markdownPage?: true
        case .webKitTab?: engine == .cef
        case nil: false
        }
    }
}
