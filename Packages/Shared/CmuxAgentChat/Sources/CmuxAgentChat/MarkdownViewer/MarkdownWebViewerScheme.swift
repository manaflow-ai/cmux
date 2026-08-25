import Foundation

/// Custom WKWebView URL schemes used by the shared markdown viewer shell.
///
/// The shell (`Resources/markdown-viewer/shell.html`) rewrites image sources
/// to these schemes so the host app mediates every image byte: local images
/// stay confined to the markdown file's directory and remote images go
/// through the consent-gated HTTPS-only loader. Both the macOS panel and the
/// iOS renderer register handlers for the same scheme strings.
public enum MarkdownWebViewerScheme {
    public static let localImage = "cmux-local-image"
    public static let remoteImage = "cmux-remote-image"
}
