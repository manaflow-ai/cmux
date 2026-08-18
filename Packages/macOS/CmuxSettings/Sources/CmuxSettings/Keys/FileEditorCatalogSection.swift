import Foundation

/// Settings under the dotted-id prefix `fileEditor.*`.
///
/// Controls the built-in plain-text file editor (the text preview that the
/// file explorer and `cmux` file routing open for editable text files). This
/// is distinct from the rendered markdown viewer, whose settings live in
/// ``MarkdownCatalogSection``.
public struct FileEditorCatalogSection: SettingCatalogSection {
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

    /// Whether recognized source files are colorized with syntax highlighting.
    ///
    /// `true` (the default) colorizes keywords, strings, comments, numbers, and
    /// types using a palette that follows the editor's light or dark background.
    /// `false` renders plain, uncolored text. Changing this applies live to open
    /// editors. Very large files always render as plain text for performance.
    public let syntaxHighlighting = DefaultsKey<Bool>(
        id: "fileEditor.syntaxHighlighting",
        defaultValue: true,
        userDefaultsKey: "fileEditor.syntaxHighlighting"
    )

    /// Creates the file editor settings section with its default keys.
    public init() {}
}
