import CmuxNextSettings

/// A place in a text file to open at: a Find result's line and column. Both are 1-based; the
/// column counts UTF-16 code units, as the code editor (Monaco) does.
///
/// The open path carries it from ``LinkOpener/openFile(_:from:markdown:at:)`` to
/// ``FilePageService``: a new editor tab sends it in `cmux.editor.config` (`reveal`), a tab that
/// already shows the file gets the `reveal` page command (``pageText``). The markdown page ignores it.
nonisolated struct FilePosition: Equatable, Sendable {
    let line: Int
    let column: Int

    init(line: Int, column: Int = 1) {
        self.line = max(1, line)
        self.column = max(1, column)
    }

    /// `{line, column}`, the config's `reveal`.
    var jsonValue: JSONValue { .object(["line": JSONValue(line), "column": JSONValue(column)]) }

    /// "line:column", the `text` of the editor's `reveal` page command.
    var pageText: String { "\(line):\(column)" }
}
