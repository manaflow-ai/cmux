public import Foundation

/// Where a browser tab hands a local file instead of loading it: Markdown opens the markdown
/// page. Video and audio stay in the tab of either engine: the Chromium build has
/// `proprietary_codecs=true ffmpeg_branding=Chrome` (H.264/HEVC, AAC; plans/cmux-next/browser.md).
/// A tab hands Markdown off (a CEF tab's shim cancels the navigation and reports
/// `localFileHandoff`). The C++ copy is the shim's `CEFHandsOffLocalFile`
/// (CEFShim/src/local_file_handoff.h); both pass schemas/local-file-handoff/vectors.json.
public nonisolated enum LocalFileHandoff: Equatable, Sendable {
    /// cmux's markdown page.
    case markdownPage
}

extension URL {
    /// Where this local file shows instead of a browser tab (``LocalFileHandoff``), nil for any
    /// other URL or a file a browser tab shows itself.
    public nonisolated var localFileHandoff: LocalFileHandoff? {
        guard scheme?.lowercased() == "file" else { return nil }
        switch pathExtension.lowercased() {
        case "md", "markdown": return .markdownPage
        default: return nil
        }
    }

    /// Whether a tab of `engine` hands a main-frame navigation to this URL off.
    public nonisolated func isHandedOff(by engine: BrowserEngineKind) -> Bool {
        localFileHandoff == .markdownPage
    }
}
