import CoreGraphics

/// The markdown viewer's Settings rows (diff-host S6). `markdown.font.size` is the page's own
/// cmux.json key (webviews/src/pages/markdown/README.md): every markdown viewer starts at it, and
/// Cmd-0 there goes back to it after Cmd-= and Cmd--.
nonisolated enum MarkdownViewerSettingsSchema {
    /// `markdown.font.size`: the body text size in points (CSS pixels in the page).
    static let fontSizePath = ["markdown", "font", "size"]
    /// The sizes the row offers; the page clamps its own Cmd-= and Cmd-- to the same range.
    static let fontSizeRange: ClosedRange<CGFloat> = 8...40
    /// The page's default (`--cmux-md-font-size`, 16px).
    static let fontSizeFallback: Double = 16

    /// Every row's key (agents may set them: looks only).
    static var keys: Set<String> { Set(descriptors.map(\.id)) }

    static var descriptors: [SettingDescriptor] {
        [SettingDescriptor(
            fontSizePath, section: .appearance,
            group: SettingsText.keyed("settings.group.markdownViewer", "Markdown Viewer"),
            title: SettingsText.keyed("settings.markdown.fontSize", "Default Font Size"),
            help: SettingsText.keyed("settings.markdown.fontSize.help",
                                     "The text size every markdown viewer opens at. Cmd-= and Cmd-- change it in one viewer; Cmd-0 goes back to this size."),
            kind: .number(SettingsSchema.points(fontSizeRange, step: 1, placeholder: fontSizeFallback)),
            default: .number(fontSizeFallback),
            keywords: ["markdown", "font", "size", "text", "zoom", "viewer"]
        )]
    }
}
