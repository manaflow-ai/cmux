import Foundation
import Observation

@MainActor
@Observable
final class TextBoxMentionCompletionController {
    private static let maxVisibleStaleSuggestionsToFilter = 500

    private(set) var suggestions: [TextBoxMentionSuggestion] = []
    private(set) var selectionIndex: Int = 0
    private(set) var isLoadingSuggestions = false

    @ObservationIgnored
    private(set) var activeQuery: TextBoxMentionQuery?
    @ObservationIgnored
    private var activeRootDirectory: String?
    @ObservationIgnored
    private var lookupTask: Task<Void, Never>?
    @ObservationIgnored
    private var lookupGeneration: UInt64 = 0
    @ObservationIgnored
    private var suggestionsQuery: TextBoxMentionQuery?
    @ObservationIgnored
    private var suggestionsRootDirectory: String?
    @ObservationIgnored
    var onStateChanged: (() -> Void)?

    var hasSuggestions: Bool {
        !suggestions.isEmpty
    }

    var isActive: Bool {
        activeQuery != nil
    }

    var shouldShowPopover: Bool {
        isActive && (hasSuggestions || isLoadingSuggestions)
    }

    var hasCurrentSuggestions: Bool {
        hasSuggestions &&
            suggestionsQuery == activeQuery &&
            suggestionsRootDirectory == activeRootDirectory
    }

    var selectedSuggestion: TextBoxMentionSuggestion? {
        guard hasCurrentSuggestions else { return nil }
        guard suggestions.indices.contains(selectionIndex) else { return nil }
        return suggestions[selectionIndex]
    }

    func refresh(for query: TextBoxMentionQuery?, rootDirectory: String?) {
        if query == nil {
            guard activeQuery != nil || activeRootDirectory != nil || !suggestions.isEmpty else { return }
            clear()
            return
        }
        guard let query else { return }

        guard activeQuery != query || activeRootDirectory != rootDirectory else { return }
        let previousActiveQuery = activeQuery
        let previousRootDirectory = activeRootDirectory
        activeQuery = query
        activeRootDirectory = rootDirectory
        selectionIndex = 0
        isLoadingSuggestions = true
        // Moving between a bare trigger and typed query changes the expected
        // result shape. Show the loading row until that exact query finishes.
        let previousQueryWasEmpty = previousActiveQuery?.query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true
        let queryIsEmpty = query.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let queryChangedToNonEmpty = previousQueryWasEmpty &&
            !queryIsEmpty
        let queryChangedToEmpty = !previousQueryWasEmpty && queryIsEmpty
        if previousActiveQuery?.trigger != query.trigger ||
            previousRootDirectory != rootDirectory ||
            queryChangedToNonEmpty ||
            queryChangedToEmpty {
            suggestions = []
            suggestionsQuery = nil
            suggestionsRootDirectory = nil
        } else if previousActiveQuery?.query != query.query,
                  !queryIsEmpty {
            filterVisibleStaleSuggestions(matching: query.query)
        }
        lookupTask?.cancel()
        lookupGeneration &+= 1
        let generation = lookupGeneration
        onStateChanged?()

        lookupTask = Task { [weak self, generation] in
            let suggestions = await TextBoxMentionIndexStore.shared.suggestions(
                for: query,
                rootDirectory: rootDirectory
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.lookupGeneration == generation,
                      self.activeQuery == query,
                      self.activeRootDirectory == rootDirectory else {
                    return
                }
                self.suggestions = suggestions
                self.suggestionsQuery = query
                self.suggestionsRootDirectory = rootDirectory
                self.isLoadingSuggestions = false
                self.selectionIndex = suggestions.isEmpty ? 0 : min(self.selectionIndex, suggestions.count - 1)
                self.onStateChanged?()
            }
        }
    }

    func moveSelection(delta: Int) {
        guard hasCurrentSuggestions else { return }
        let count = suggestions.count
        selectionIndex = (selectionIndex + delta + count) % count
        onStateChanged?()
    }

    func clear() {
        activeQuery = nil
        activeRootDirectory = nil
        suggestions = []
        suggestionsQuery = nil
        suggestionsRootDirectory = nil
        isLoadingSuggestions = false
        selectionIndex = 0
        lookupTask?.cancel()
        lookupTask = nil
        lookupGeneration &+= 1
        onStateChanged?()
    }

    private func filterVisibleStaleSuggestions(matching query: String) {
        let normalizedQuery = Self.normalizedMentionSearchText(query)
        guard !normalizedQuery.isEmpty, !suggestions.isEmpty else { return }
        if suggestions.count > Self.maxVisibleStaleSuggestionsToFilter {
            // The index store caps visible rows at this size; oversized injected
            // stale state is safer to clear than filter on the main actor.
            suggestions = []
        } else {
            suggestions = suggestions.filter { suggestion in
                Self.title(suggestion.title, matchesNormalizedQuery: normalizedQuery)
            }
        }
        suggestionsQuery = nil
        suggestionsRootDirectory = nil
        selectionIndex = suggestions.isEmpty ? 0 : min(selectionIndex, suggestions.count - 1)
    }

    private static func title(_ title: String, matchesNormalizedQuery normalizedQuery: String) -> Bool {
        let normalizedTitle = normalizedMentionSearchText(title)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/$@"))
        guard !normalizedQuery.isEmpty else { return true }
        guard !normalizedTitle.isEmpty else { return false }
        if normalizedTitle.contains(normalizedQuery) { return true }

        var candidateIndex = normalizedTitle.startIndex
        for queryCharacter in normalizedQuery {
            guard let matchIndex = normalizedTitle[candidateIndex...].firstIndex(of: queryCharacter) else {
                return false
            }
            candidateIndex = normalizedTitle.index(after: matchIndex)
        }
        return true
    }

    private static func normalizedMentionSearchText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    deinit {
        lookupTask?.cancel()
    }

#if DEBUG
    func debugSetState(
        query: TextBoxMentionQuery?,
        suggestions debugSuggestions: [TextBoxMentionSuggestion],
        rootDirectory: String? = nil,
        isLoading: Bool = false
    ) {
        lookupTask?.cancel()
        lookupTask = nil
        lookupGeneration &+= 1
        activeQuery = query
        activeRootDirectory = rootDirectory
        suggestions = debugSuggestions
        suggestionsQuery = query
        suggestionsRootDirectory = rootDirectory
        isLoadingSuggestions = isLoading
        selectionIndex = suggestions.isEmpty ? 0 : min(selectionIndex, suggestions.count - 1)
        onStateChanged?()
    }

    var debugSuggestionCount: Int {
        suggestions.count
    }

    var debugHasCurrentSuggestions: Bool {
        hasCurrentSuggestions
    }

    var debugShouldShowPopover: Bool {
        shouldShowPopover
    }

    var debugSuggestionTitles: [String] {
        suggestions.map(\.title)
    }
#endif
}
