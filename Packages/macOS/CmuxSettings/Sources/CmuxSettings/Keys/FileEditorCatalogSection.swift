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

    /// Whether source files receive token colors from the highlight engine.
    public let syntaxHighlighting = DefaultsKey<Bool>(
        id: "fileEditor.syntaxHighlighting",
        defaultValue: true,
        userDefaultsKey: "fileEditor.syntaxHighlighting"
    )

    /// Whether the editor shows a line-number gutter.
    public let lineNumbers = DefaultsKey<Bool>(
        id: "fileEditor.lineNumbers",
        defaultValue: true,
        userDefaultsKey: "fileEditor.lineNumbers"
    )

    /// Whether the editor draws vertical indent guides.
    public let indentGuides = DefaultsKey<Bool>(
        id: "fileEditor.indentGuides",
        defaultValue: true,
        userDefaultsKey: "fileEditor.indentGuides"
    )

    /// Whether the caret's line is highlighted when the selection is empty.
    public let currentLineHighlight = DefaultsKey<Bool>(
        id: "fileEditor.currentLineHighlight",
        defaultValue: true,
        userDefaultsKey: "fileEditor.currentLineHighlight"
    )

    /// Columns per tab stop, used by indent guides.
    public let tabWidth = DefaultsKey<Int>(
        id: "fileEditor.tabWidth",
        defaultValue: 4,
        userDefaultsKey: "fileEditor.tabWidth"
    )

    /// Creates the file editor settings section with its default keys.
    public init() {}
}
