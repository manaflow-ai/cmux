import Foundation
import Observation

/// Pane-local Settings navigation state.
///
/// Every Settings root owns one model. Search state therefore stays independent
/// when several Settings panes are open, while setting values continue to
/// converge through the shared stores in ``SettingsRuntime``.
@MainActor
@Observable
final class SettingsSidebarModel {
    var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            visibleEntries = searchIndex.match(searchText)
            searchEvaluationCount &+= 1
        }
    }

    private(set) var visibleEntries: [SettingsSearchIndex.Entry]
    private(set) var searchEvaluationCount = 1

    @ObservationIgnored private let searchIndex: SettingsSearchIndex

    init(searchIndex: SettingsSearchIndex) {
        self.searchIndex = searchIndex
        self.visibleEntries = searchIndex.match("")
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
