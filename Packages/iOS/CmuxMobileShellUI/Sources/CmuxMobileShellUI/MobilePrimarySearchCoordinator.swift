#if os(iOS)
import Observation

/// Owns the native Search tab's scope, presentation lifecycle, platform draft
/// text, and committed filters. The shell keeps one coordinator above the tab
/// scaffold so search edits do not invalidate shell-wide presentation state.
@MainActor
@Observable
final class MobilePrimarySearchCoordinator {
    var scope: MobilePrimarySearchScope
    var isPresented = false
    var workspaces = ""
    var notifications = ""

    private var phase: MobilePrimarySearchPhase = .inactive
    private var workspaceNativeSearchText = ""
    private var notificationNativeSearchText = ""

    init(initialScope: MobilePrimarySearchScope = .workspaces) {
        scope = initialScope
    }

    func synchronizeSelection(_ selection: MobilePrimaryTab) {
        guard let selectedScope = selection.searchScope else { return }
        scope = selectedScope
        syncNativeSearchText(fromCommittedQueryFor: selectedScope)
    }

    func setPresentation(_ presented: Bool) {
        if isPresented, !presented {
            beginDeactivation(for: scope)
        }
        isPresented = presented
        if presented {
            phase = .active(scope)
            syncNativeSearchText(fromCommittedQueryFor: scope)
        }
    }

    func commitSubmit() -> MobilePrimaryTab {
        let submittedScope = scope
        beginDeactivation(for: submittedScope)
        isPresented = false
        return submittedScope.primaryTab
    }

    func deactivateCurrentSearch() {
        beginDeactivation(for: scope)
        isPresented = false
    }

    func updateLifecycle(scope: MobilePrimarySearchScope, isSearching: Bool) {
        if isSearching {
            phase = .active(scope)
            self.scope = scope
            syncNativeSearchText(fromCommittedQueryFor: scope)
        } else if phase == .active(scope) {
            beginDeactivation(for: scope)
        }
    }

    func activeNativeSearchText() -> String {
        nativeSearchText(for: scope)
    }

    func commitActiveNativeSearchText(_ value: String) {
        commitNativeSearchText(value, for: scope)
    }

    func commitNativeSearchText(_ value: String, for scope: MobilePrimarySearchScope) {
        guard acceptsNativeEdit(for: scope) else {
            syncNativeSearchText(fromCommittedQueryFor: scope)
            return
        }
        setNativeSearchText(value, for: scope)
        setCommittedSearchText(value, for: scope)
    }

    func acceptsNativeEdit(for scope: MobilePrimarySearchScope) -> Bool {
        phase == .active(scope) && isPresented
    }

    private func nativeSearchText(for scope: MobilePrimarySearchScope) -> String {
        switch scope {
        case .workspaces:
            workspaceNativeSearchText
        case .notifications:
            notificationNativeSearchText
        }
    }

    private func committedSearchText(for scope: MobilePrimarySearchScope) -> String {
        switch scope {
        case .workspaces:
            workspaces
        case .notifications:
            notifications
        }
    }

    private func setNativeSearchText(_ value: String, for scope: MobilePrimarySearchScope) {
        switch scope {
        case .workspaces:
            workspaceNativeSearchText = value
        case .notifications:
            notificationNativeSearchText = value
        }
    }

    private func setCommittedSearchText(_ value: String, for scope: MobilePrimarySearchScope) {
        switch scope {
        case .workspaces:
            workspaces = value
        case .notifications:
            notifications = value
        }
    }

    private func syncNativeSearchText(fromCommittedQueryFor scope: MobilePrimarySearchScope) {
        setNativeSearchText(committedSearchText(for: scope), for: scope)
    }

    private func beginDeactivation(for scope: MobilePrimarySearchScope) {
        phase = .deactivating(scope)
        syncNativeSearchText(fromCommittedQueryFor: scope)
    }
}

extension MobilePrimaryTab {
    var searchScope: MobilePrimarySearchScope? {
        switch self {
        case .workspaces:
            .workspaces
        case .notifications:
            .notifications
        case .search:
            nil
        }
    }
}

extension MobilePrimarySearchScope {
    var primaryTab: MobilePrimaryTab {
        switch self {
        case .workspaces:
            .workspaces
        case .notifications:
            .notifications
        }
    }
}
#endif
