/// One syntax-highlighting cache request.
struct DiffHighlightRequest: Sendable, Equatable {
    /// Row identity receiving the result.
    let rowID: String
    /// Plain source text.
    let text: String
    /// Inferred Highlight.js language.
    let language: String

    /// Creates a row highlight request.
    init(rowID: String, text: String, language: String) {
        self.rowID = rowID
        self.text = text
        self.language = language
    }
}
