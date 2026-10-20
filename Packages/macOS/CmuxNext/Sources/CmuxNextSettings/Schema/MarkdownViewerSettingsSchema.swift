import CoreGraphics

/// The markdown viewer's Settings rows (diff-host S6, reading settings 2026-10-19): the keys the
/// viewer's Reading Settings popover (the toolbar's Aa button) writes, with the page's defaults and
/// ranges (webviews/src/pages/markdown/settings.ts `MARKDOWN_READING`). `markdown.font.size` is the
/// size every viewer starts at, and Cmd-0 there goes back to it after Cmd-= and Cmd--.
nonisolated enum MarkdownViewerSettingsSchema {
    /// `markdown.font.size`: the body text size in points (CSS pixels in the page).
    static let fontSizePath = ["markdown", "font", "size"]
    /// The sizes the row offers; the page clamps its own Cmd-= and Cmd-- to the same range.
    static let fontSizeRange: ClosedRange<CGFloat> = 8...40
    /// The page's default (`--cmux-md-font-size`, 16px).
    static let fontSizeFallback: Double = 16

    /// `markdown.layout.width`: the widest the text column gets, in characters of the body font.
    /// Wide enough for an ultrawide monitor (1000 characters is about 8,800 points at 16 points);
    /// Full Width is its own key, never the top of this range.
    static let widthRange: ClosedRange<Double> = 30...1000
    /// The page's default reading width (`MARKDOWN_READING.width`).
    static let widthFallback: Double = 72
    /// `markdown.code.scale`: code size as a share of the body text size.
    static let codeScaleRange: ClosedRange<Double> = 0.6...1.25
    /// The page's default (`--cmux-md-code-scale`, as GitHub's 85%).
    static let codeScaleFallback: Double = 0.875

    /// Every row's key (agents may set them: looks only).
    static var keys: Set<String> { Set(descriptors.map(\.id)) }

    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.markdownViewer", "Markdown Viewer")
        func row(_ path: [String], _ title: SettingText, help: SettingText? = nil, _ kind: SettingKind,
                 _ value: JSONValue, _ keywords: [String]) -> SettingDescriptor {
            SettingDescriptor(["markdown"] + path, section: .appearance, group: group, title: title, help: help,
                              kind: kind, default: value, keywords: ["markdown", "viewer", "reading"] + keywords)
        }
        return [
            row(["layout", "width"], SettingsText.keyed("settings.markdown.width", "Text Width"),
                help: SettingsText.keyed("settings.markdown.width.help",
                                         "The widest a line of text gets, in characters (30 to 1000). On a wider window the text stays centered with margins. Wide tables and code scroll sideways in their own box."),
                .number(SettingNumber(widthRange, step: 1, unit: .count, placeholder: widthFallback)), .number(widthFallback),
                ["width", "max width", "column", "measure", "line length", "wide", "ultrawide", "monitor"]),
            row(["layout", "fullWidth"], SettingsText.keyed("settings.markdown.fullWidth", "Full Width"),
                help: SettingsText.keyed("settings.markdown.fullWidth.help", "Text fills the whole pane instead of the text width."),
                .toggle, .bool(false), ["full", "width", "wide"]),
            SettingDescriptor(
                fontSizePath, section: .appearance, group: group,
                title: SettingsText.keyed("settings.markdown.fontSize", "Default Font Size"),
                help: SettingsText.keyed("settings.markdown.fontSize.help",
                                         "The text size every markdown viewer opens at. Cmd-= and Cmd-- change it in one viewer; Cmd-0 goes back to this size."),
                kind: .number(SettingsSchema.points(fontSizeRange, step: 1, placeholder: fontSizeFallback)),
                default: .number(fontSizeFallback),
                keywords: ["markdown", "font", "size", "text", "zoom", "viewer", "reading"]
            ),
            row(["font", "preset"], SettingsText.keyed("settings.markdown.fontPreset", "Font"),
                .choice([
                    SettingChoice("system", SettingsText.keyed("settings.choice.markdownFontSystem", "System")),
                    SettingChoice("serif", SettingsText.keyed("settings.choice.markdownFontSerif", "Serif")),
                    SettingChoice("mono", SettingsText.keyed("settings.choice.markdownFontMono", "Monospaced")),
                ]),
                .string("system"), ["font", "family", "serif", "monospace", "typeface"]),
            row(["font", "lineHeight"], SettingsText.keyed("settings.markdown.lineHeight", "Line Height"),
                .number(SettingNumber(1...2.4, step: 0.05, unit: .fraction, placeholder: 1.6)), .number(1.6),
                ["line height", "leading", "line spacing"]),
            row(["spacing", "paragraph"], SettingsText.keyed("settings.markdown.paragraphSpacing", "Paragraph Spacing"),
                help: SettingsText.keyed("settings.markdown.paragraphSpacing.help", "The gap after each paragraph, as a share of the text size."),
                .number(SettingNumber(0...3, step: 0.1, unit: .fraction, placeholder: 1)), .number(1),
                ["paragraph", "spacing", "gap", "margin"]),
            row(["code", "scale"], SettingsText.keyed("settings.markdown.codeSize", "Code Font Size"),
                help: SettingsText.keyed("settings.markdown.codeScale.help",
                                         "Code as a share of the text size. A monospaced font looks bigger than the text font at the same size, so code is a little smaller by default."),
                .number(SettingNumber(codeScaleRange, step: 0.025, unit: .fraction, placeholder: codeScaleFallback)),
                .number(codeScaleFallback), ["code", "font", "size", "monospace", "scale"]),
            // A fixed code block size in pixels; `code.scale` is the row. Kept so cmux.json files that
            // set it still validate and the viewer can clear it when the user picks a code size.
            SettingDescriptor(
                ["markdown", "code", "blockSize"], section: .appearance, group: group,
                title: SettingsText.keyed("settings.markdown.codeBlockSize", "Code Block Size"),
                kind: .number(SettingsSchema.points(8...32, step: 1, placeholder: 14)), default: nil,
                keywords: ["markdown", "viewer", "reading", "code", "font", "size", "monospace"]
            )
            .hiddenFromSettingsPage("a fixed pixel size; Code Font Size (markdown.code.scale) is the row"),
            row(["tables"], SettingsText.keyed("settings.markdown.tables", "Wide Tables"),
                .choice([
                    SettingChoice("scroll", SettingsText.keyed("settings.choice.markdownTablesScroll", "Scroll Sideways")),
                    SettingChoice("wrap", SettingsText.keyed("settings.choice.markdownTablesWrap", "Wrap to Fit")),
                ]),
                .string("scroll"), ["table", "wrap", "scroll", "wide"]),
            row(["theme"], SettingsText.keyed("settings.markdown.theme", "Page Theme"),
                .choice([
                    SettingChoice("app", SettingsText.keyed("settings.choice.markdownThemeApp", "Match App")),
                    SettingChoice("light", SettingsText.keyed("settings.choice.markdownThemeLight", "Light")),
                    SettingChoice("dark", SettingsText.keyed("settings.choice.markdownThemeDark", "Dark")),
                ]),
                .string("app"), ["theme", "light", "dark", "appearance", "paper"]),
        ]
    }
}
