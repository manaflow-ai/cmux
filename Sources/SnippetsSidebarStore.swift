import Combine
import CmuxTextActions
import Foundation

/// State behind the Snippets sidebar: the loaded text actions, the live
/// query, the ranked results, and the keyboard selection. Owned by the
/// sidebar view; attached to the window's `CmuxConfigStore` while visible.
@MainActor
final class SnippetsSidebarStore: ObservableObject {
    @Published private(set) var entries: [CmuxSnippetMenuEntry] = []
    @Published private(set) var results: [CmuxSnippetMenuEntry] = []
    @Published private(set) var selectedActionID: String?
    @Published var query: String = "" {
        didSet { refreshResults() }
    }

    private var revisionObservation: AnyCancellable?

    var selectedEntry: CmuxSnippetMenuEntry? {
        guard let selectedActionID else { return nil }
        return results.first { $0.actionID == selectedActionID }
    }

    /// Loads the entries now and again on every config revision until
    /// `detach()`; the store never retains the config store.
    func attach(configStore: CmuxConfigStore) {
        reload(from: configStore)
        revisionObservation = configStore.$configRevision
            .dropFirst()
            .sink { [weak self, weak configStore] _ in
                guard let self, let configStore else { return }
                self.reload(from: configStore)
            }
    }

    func detach() {
        revisionObservation = nil
    }

    func select(actionID: String) {
        guard results.contains(where: { $0.actionID == actionID }) else { return }
        selectedActionID = actionID
    }

    /// Moves the selection by `delta` rows, clamped to the results.
    func moveSelection(by delta: Int) {
        guard !results.isEmpty else {
            selectedActionID = nil
            return
        }
        let current = results.firstIndex { $0.actionID == selectedActionID } ?? 0
        let next = min(max(current + delta, 0), results.count - 1)
        selectedActionID = results[next].actionID
    }

    private func reload(from configStore: CmuxConfigStore) {
        entries = configStore.snippetMenuEntries()
        refreshResults()
    }

    /// Recomputes the ranked results and keeps the selection on a visible
    /// row, falling back to the top result.
    private func refreshResults() {
        results = CmuxSnippetSearch.filter(entries, query: query)
        if let selectedActionID, results.contains(where: { $0.actionID == selectedActionID }) {
            return
        }
        selectedActionID = results.first?.actionID
    }
}
