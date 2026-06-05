import Foundation
import Observation

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

@MainActor
@Observable
final class TextBoxMentionCompletionController {
    private static let maxVisibleStaleSuggestionsToFilter = 500

    private(set) var suggestions: [TextBoxMentionSuggestion] = []
    private(set) var selectionIndex: Int = 0
    private(set) var isLoadingSuggestions = false
    private(set) var renderState = TextBoxMentionCompletionRenderState.hidden

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
    private var locallyFilteredSuggestions: [TextBoxMentionSuggestion]?
    @ObservationIgnored
    var onStateChanged: (() -> Void)?

    var hasSuggestions: Bool {
        !suggestions.isEmpty
    }

    var visibleSuggestions: [TextBoxMentionSuggestion] {
        renderState.suggestions
    }

    var hasVisibleSuggestions: Bool {
        !visibleSuggestions.isEmpty
    }

    var hasAcceptableSuggestions: Bool {
        hasCurrentSuggestions
    }

    var isActive: Bool {
        activeQuery != nil
    }

    var shouldShowPopover: Bool {
        isActive && renderState.shouldShowPopover
    }

    var hasCurrentSuggestions: Bool {
        hasSuggestions &&
            suggestionsQuery == activeQuery &&
            suggestionsRootDirectory == activeRootDirectory
    }

    var selectedSuggestion: TextBoxMentionSuggestion? {
        guard visibleSuggestions.indices.contains(renderState.selectionIndex) else { return nil }
        return visibleSuggestions[renderState.selectionIndex]
    }

    func canAccept(_ suggestion: TextBoxMentionSuggestion) -> Bool {
        hasAcceptableSuggestions && suggestions.contains(where: { $0.id == suggestion.id })
    }

    func matchesCurrentInput(query: TextBoxMentionQuery?, rootDirectory: String?) -> Bool {
        guard let query else {
            return activeQuery == nil
        }
        return activeQuery == query && activeRootDirectory == rootDirectory
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
        let previousQueryWasEmpty = previousActiveQuery?.query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true
        let queryIsEmpty = query.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let queryChangedToEmpty = !previousQueryWasEmpty && queryIsEmpty
        if previousActiveQuery?.trigger != query.trigger ||
            previousRootDirectory != rootDirectory ||
            queryChangedToEmpty {
            suggestions = []
            suggestionsQuery = nil
            suggestionsRootDirectory = nil
            locallyFilteredSuggestions = nil
        } else if previousActiveQuery?.query != query.query,
                  !queryIsEmpty {
            filterVisibleStaleSuggestions(matching: query.query)
        }
        lookupTask?.cancel()
        lookupGeneration &+= 1
        let generation = lookupGeneration
        publishStateChanged()

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
                self.locallyFilteredSuggestions = nil
                self.isLoadingSuggestions = false
                self.selectionIndex = suggestions.isEmpty ? 0 : min(self.selectionIndex, suggestions.count - 1)
                self.publishStateChanged()
            }
        }
    }

    func moveSelection(delta: Int) {
        guard hasVisibleSuggestions else { return }
        let count = visibleSuggestions.count
        selectionIndex = (selectionIndex + delta + count) % count
        publishStateChanged()
    }

    func clear() {
        activeQuery = nil
        activeRootDirectory = nil
        suggestions = []
        suggestionsQuery = nil
        suggestionsRootDirectory = nil
        locallyFilteredSuggestions = nil
        isLoadingSuggestions = false
        selectionIndex = 0
        lookupTask?.cancel()
        lookupTask = nil
        lookupGeneration &+= 1
        publishStateChanged()
    }

    private func publishStateChanged() {
        updateRenderState()
        onStateChanged?()
    }

    private func updateRenderState() {
        let rows: [TextBoxMentionSuggestion]
        if hasCurrentSuggestions {
            rows = suggestions
        } else if isLoadingSuggestions {
            rows = locallyFilteredSuggestions ?? []
        } else {
            rows = []
        }
        renderState = TextBoxMentionCompletionRenderState(
            suggestions: rows,
            selectionIndex: rows.indices.contains(selectionIndex) ? selectionIndex : 0,
            searchTerm: activeQuery?.query ?? "",
            isLoading: isLoadingSuggestions
        )
    }

    private func filterVisibleStaleSuggestions(matching query: String) {
        let normalizedQuery = Self.normalizedMentionSearchText(query)
        guard !normalizedQuery.isEmpty, !suggestions.isEmpty else { return }
        let filteredSuggestions: [TextBoxMentionSuggestion]
        if suggestions.count > Self.maxVisibleStaleSuggestionsToFilter {
            // The index store caps visible rows at this size; oversized injected
            // stale state is safer to clear than filter on the main actor.
            filteredSuggestions = []
        } else {
            filteredSuggestions = suggestions.filter { suggestion in
                Self.title(suggestion.title, matchesNormalizedQuery: normalizedQuery)
            }
        }
        locallyFilteredSuggestions = filteredSuggestions
        suggestionsQuery = nil
        suggestionsRootDirectory = nil
        selectionIndex = filteredSuggestions.isEmpty ? 0 : min(selectionIndex, filteredSuggestions.count - 1)
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
        locallyFilteredSuggestions = nil
        isLoadingSuggestions = isLoading
        selectionIndex = suggestions.isEmpty ? 0 : min(selectionIndex, suggestions.count - 1)
        publishStateChanged()
    }

    var debugSuggestionCount: Int {
        suggestions.count
    }

    var debugVisibleSuggestionCount: Int {
        visibleSuggestions.count
    }

    var debugHasCurrentSuggestions: Bool {
        hasCurrentSuggestions
    }

    var debugShouldShowPopover: Bool {
        shouldShowPopover
    }

    var debugSuggestionTitles: [String] {
        visibleSuggestions.map(\.title)
    }
#endif
}
