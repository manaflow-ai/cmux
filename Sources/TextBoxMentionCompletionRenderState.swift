import Foundation

struct TextBoxMentionCompletionRenderState: Equatable, Sendable {
    var suggestions: [TextBoxMentionSuggestion]
    var selectionIndex: Int
    var searchTerm: String
    var isLoading: Bool
    var identity: Int

    static let hidden = TextBoxMentionCompletionRenderState(suggestions: [])

    init(
        suggestions: [TextBoxMentionSuggestion],
        selectionIndex: Int = 0,
        searchTerm: String = "",
        isLoading: Bool = false
    ) {
        self.suggestions = suggestions
        self.selectionIndex = selectionIndex
        self.searchTerm = searchTerm
        self.isLoading = isLoading

        var hasher = Hasher()
        hasher.combine(searchTerm)
        hasher.combine(isLoading)
        for suggestion in suggestions {
            hasher.combine(suggestion.id)
        }
        identity = hasher.finalize()
    }

    var shouldShowPopover: Bool {
        !suggestions.isEmpty || isLoading
    }
}
