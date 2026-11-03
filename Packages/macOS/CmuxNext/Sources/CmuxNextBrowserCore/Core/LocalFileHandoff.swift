public import Foundation

/// Where a browser tab hands a local file instead of loading it: Markdown opens the markdown
/// page, and the video and audio the Chromium build cannot decode (H.264/HEVC and AAC; the fork
/// builds without proprietary codecs, plans/cmux-next/browser.md) open in a WebKit tab, which
/// plays them through AVFoundation. A CEF tab hands both off (the shim cancels the navigation and
/// reports `localFileHandoff`); a WebKit tab hands off Markdown only. The C++ copy is the shim's
/// `CEFHandsOffLocalFile` (CEFShim/src/local_file_handoff.h); both pass
/// schemas/local-file-handoff/vectors.json.
public nonisolated enum LocalFileHandoff: Equatable, Sendable {
    /// cmux's markdown page.
    case markdownPage
    /// A WebKit browser tab.
    case webKitTab
}

extension URL {
    /// Where this local file shows instead of a browser tab (``LocalFileHandoff``), nil for any
    /// other URL or a file a browser tab shows itself.
    public nonisolated var localFileHandoff: LocalFileHandoff? {
        guard scheme?.lowercased() == "file" else { return nil }
        switch pathExtension.lowercased() {
        case "md", "markdown": return .markdownPage
        // Video and audio a CEF tab cannot play: H.264/HEVC video, AAC audio.
        case "mp4", "mov", "m4v", "m4a", "aac": return .webKitTab
        default: return nil
        }
    }

    /// Whether a tab of `engine` hands a main-frame navigation to this URL off.
    public nonisolated func isHandedOff(by engine: BrowserEngineKind) -> Bool {
        switch localFileHandoff {
        case .markdownPage?: true
        case .webKitTab?: engine == .cef
        case nil: false
        }
    }
}
