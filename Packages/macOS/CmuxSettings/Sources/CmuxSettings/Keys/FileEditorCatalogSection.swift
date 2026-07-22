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

    /// Which renderer draws the text editor.
    ///
    /// `"plain"` (the default) is the established NSTextView-based plain-text
    /// editor. `"code"` renders the CodeMirror-based code editor with syntax
    /// highlighting, code folding, and in-editor search. Changing this
    /// applies to open editors live.
    public let engine = DefaultsKey<String>(
        id: "fileEditor.engine",
        defaultValue: "plain",
        userDefaultsKey: "fileEditor.engine"
    )

    /// Creates the file editor settings section with its default keys.
    public init() {}
}
