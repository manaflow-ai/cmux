public import CmuxNextSettings

nonisolated extension ChatQuote {
    /// A quote from a viewer page's selection reply (`cmux.markdown.selection`,
    /// `cmux.editor.selection`): `{text, startLine?, endLine?}`. Nil for a null reply or blank text.
    ///
    /// - Parameters:
    ///   - selection: The page's reply.
    ///   - source: The file the page shows.
    ///   - kind: The page's viewer kind.
    ///   - comment: The user's comment, empty for none.
    public init?(selection: JSONValue, source: String, kind: Kind, comment: String = "") {
        guard let object = selection.objectValue, let text = object["text"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var lines: ClosedRange<Int>?
        if let start = object["startLine"]?.intValue, let end = object["endLine"]?.intValue, start >= 1 {
            lines = start...max(start, end)
        }
        self.init(source: source, kind: kind, lines: lines, quoted: text, comment: comment)
    }
}
