import Foundation

/// Settings under the dotted-id prefix `fileEditor.*`.
///
/// Controls the built-in plain-text file editor (the text preview that the
/// file explorer and `cmux` file routing open for editable text files). This
/// is distinct from the rendered markdown viewer, whose settings live in
/// ``MarkdownCatalogSection``.
public struct FileEditorCatalogSection: SettingCatalogSection {
    /// Default font size, in points, for newly opened editors.
    ///
    /// The editor's zoom shortcuts still adjust an individual editor on top of
    /// this default and Cmd-0 returns to it.
    public let fontSize = DefaultsKey<Int>(
        id: "fileEditor.fontSize",
        defaultValue: 13,
        userDefaultsKey: "fileEditor.fontSize"
    )

    /// Default font family for newly opened editors.
    ///
    /// An empty value keeps the established monospaced system font.
    public let fontFamily = DefaultsKey<String>(
        id: "fileEditor.fontFamily",
        defaultValue: "",
        userDefaultsKey: "fileEditor.fontFamily"
    )

    /// Paragraph line-height multiplier for the editor.
    ///
    /// `1.0` preserves the natural font leading; larger values add readable
    /// space between lines.
    public let lineHeight = DefaultsKey<Double>(
        id: "fileEditor.lineHeight",
        defaultValue: 1.0,
        userDefaultsKey: "fileEditor.lineHeight"
    )

    /// Whether long lines soft-wrap at the editor's right edge.
    ///
    /// `false` (the default) preserves the established behavior: lines extend
    /// past the viewport and a horizontal scroller appears. `true` wraps each
    /// line to the visible width and hides the horizontal scroller, the way a
    /// prose editor does. Changing this applies live to open editors.
    public let wordWrap = DefaultsKey<Bool>(
        id: "fileEditor.wordWrap",
        defaultValue: false,
        userDefaultsKey: "fileEditor.wordWrap"
    )

    /// Creates the file editor settings section with its default keys.
    public init() {}
}
