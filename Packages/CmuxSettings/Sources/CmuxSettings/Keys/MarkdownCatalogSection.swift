import Foundation

/// Settings under the dotted-id prefix `markdown.*`.
///
/// Controls the built-in markdown viewer that `cmux markdown open` and the file
/// explorer use. The viewer renders into a WKWebView and scales with
/// `WKWebView.pageZoom`, so ``fontSize`` is the body font size in points.
public struct MarkdownCatalogSection: SettingCatalogSection {
    /// Default body font size, in points, for newly opened markdown viewers.
    ///
    /// Each viewer can still be zoomed live with the Markdown Viewer zoom
    /// shortcuts; this is the size every new viewer starts at and the size that
    /// "Actual Size" resets to. Per-invocation overrides come from
    /// `cmux markdown open --font-size <points>`.
    public let fontSize = DefaultsKey<Int>(
        id: "markdown.fontSize",
        defaultValue: 15,
        userDefaultsKey: "markdown.fontSize"
    )

    /// Creates the markdown settings section with its default keys.
    public init() {}
}
