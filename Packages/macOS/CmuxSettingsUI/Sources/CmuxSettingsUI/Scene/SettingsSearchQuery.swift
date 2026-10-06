import Observation
import SwiftUI

/// The settings search query and the sidebar results it has produced.
///
/// Typing must stay cheap even on a slow, loaded Mac: a keystroke only
/// stores ``text``, which nothing but the search field reads. Matching runs
/// once the user pauses for ``debounce``, off the main actor, and only the
/// finished result list (``results``) is published to the sidebar rows. The
/// root window never reads either property in its body, so a keystroke does
/// not re-render the detail pane or the split view.
@MainActor
@Observable
final class SettingsSearchQuery {
    /// Matches a query against the index. Runs off the main actor.
    typealias Matcher = @Sendable (String) -> [SettingsSearchIndex.Entry]

    /// The text in the search field, updated on every keystroke.
    var text: String {
        get {
            access(keyPath: \.text)
            return storedText
        }
        set {
            guard newValue != storedText else { return }
            withMutation(keyPath: \.text) { storedText = newValue }
            scheduleFiltering()
        }
    }

    /// Results for ``appliedText``: section rows for a blank query, ranked
    /// hits otherwise.
    private(set) var results: [SettingsSearchIndex.Entry]
    /// The query ``results`` were computed for.
    private(set) var appliedText = ""

    /// Whether the field holds a non-blank query. Read by actions, not views.
    var isSearching: Bool { Self.isSearching(storedText) }
    /// Whether the sidebar is showing ranked search hits rather than the
    /// grouped browse list.
    var isShowingSearchResults: Bool { Self.isSearching(appliedText) }

    /// Runs when the applied query becomes blank, so the owner can move the
    /// selection from a deep setting hit back to its section row.
    @ObservationIgnored var onQueryCleared: @MainActor () -> Void = {}

    @ObservationIgnored private var storedText = ""
    @ObservationIgnored private let match: Matcher
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var filterTask: Task<Void, Never>?

    /// - Parameters:
    ///   - match: Query matcher, called off the main actor.
    ///   - debounce: Quiet period after the last keystroke before matching.
    init(match: @escaping Matcher, debounce: Duration = .milliseconds(100)) {
        self.match = match
        self.debounce = debounce
        self.results = match("")
    }

    convenience init(index: SettingsSearchIndex, debounce: Duration = .milliseconds(100)) {
        self.init(match: { index.match($0) }, debounce: debounce)
    }

    /// Waits for any scheduled filtering to finish. Tests use it to observe
    /// the applied results without sleeping.
    func settle() async {
        while let task = filterTask {
            await task.value
            if filterTask == task { filterTask = nil }
        }
    }

    private func scheduleFiltering() {
        filterTask?.cancel()
        let query = storedText
        // Clearing the field restores the browse list at once; there is
        // nothing to rank, and the user expects the categories back.
        guard Self.isSearching(query) else {
            filterTask = nil
            apply(match(query), for: query)
            return
        }
        let match = match
        let debounce = debounce
        filterTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            let matches = await Task.detached(priority: .userInitiated) { match(query) }.value
            guard !Task.isCancelled, let self, self.storedText == query else { return }
            self.apply(matches, for: query)
        }
    }

    private func apply(_ matches: [SettingsSearchIndex.Entry], for query: String) {
        let wasShowingSearchResults = isShowingSearchResults
        if results != matches { results = matches }
        if appliedText != query { appliedText = query }
        if wasShowingSearchResults, !isShowingSearchResults {
            onQueryCleared()
        }
    }

    private static func isSearching(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
