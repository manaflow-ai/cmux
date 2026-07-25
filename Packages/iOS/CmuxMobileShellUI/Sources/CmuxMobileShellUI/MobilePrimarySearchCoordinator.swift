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
    var workspaces = "" {
        didSet { normalizeCommittedSearchText(for: .workspaces, oldValue: oldValue) }
    }
    var notifications = "" {
        didSet { normalizeCommittedSearchText(for: .notifications, oldValue: oldValue) }
    }
    private(set) var activationGeneration: UInt64 = 0

    private var phase: MobilePrimarySearchPhase = .inactive
    private var workspaceNativeSearchText = ""
    private var notificationNativeSearchText = ""

    init(initialScope: MobilePrimarySearchScope = .workspaces) {
        scope = initialScope
    }

    func synchronizeSelection(_ selection: MobilePrimaryTab) {
        guard let selectedScope = selection.searchScope else { return }
        guard scope != selectedScope else { return }
        scope = selectedScope
        syncNativeSearchText(fromCommittedQueryFor: selectedScope)
    }

    func setPresentation(_ presented: Bool) {
        if isPresented, !presented {
            commitNativeDraft(for: scope)
            beginDeactivation(for: scope)
        }
        isPresented = presented
        if presented {
            activate(scope: scope)
        }
    }

    func commitSubmit() -> MobilePrimaryTab {
        let submittedScope = scope
        commitNativeDraft(for: submittedScope)
        beginDeactivation(for: submittedScope)
        isPresented = false
        return submittedScope.primaryTab
    }

    func deactivateCurrentSearch() {
        commitNativeDraft(for: scope)
        beginDeactivation(for: scope)
        isPresented = false
    }

    func updateLifecycle(scope: MobilePrimarySearchScope, isSearching: Bool) {
        if isSearching {
            activate(scope: scope)
        } else if phase == .active(scope) {
            commitNativeDraft(for: scope)
            beginDeactivation(for: scope)
        }
    }

    func activeNativeSearchText() -> String {
        nativeSearchText(for: scope)
    }

    func nativeSearchText(for scope: MobilePrimarySearchScope) -> String {
        switch scope {
        case .workspaces:
            workspaceNativeSearchText
        case .notifications:
            notificationNativeSearchText
        }
    }

    func updateNativeSearchText(
        _ value: String,
        for scope: MobilePrimarySearchScope,
        activationGeneration: UInt64
    ) {
        guard acceptsNativeEdit(for: scope, activationGeneration: activationGeneration) else {
            if phase != .active(scope) || !isPresented {
                syncNativeSearchText(fromCommittedQueryFor: scope)
            }
            return
        }
        setNativeSearchText(value, for: scope)
    }

    func acceptsNativeEdit(
        for scope: MobilePrimarySearchScope,
        activationGeneration: UInt64
    ) -> Bool {
        phase == .active(scope)
            && isPresented
            && self.activationGeneration == activationGeneration
    }

    func searchDestinationText(for scope: MobilePrimarySearchScope) -> String {
        if phase == .active(scope), isPresented {
            return nativeSearchText(for: scope)
        }
        return committedSearchText(for: scope)
    }

    func committedSearchText(for scope: MobilePrimarySearchScope) -> String {
        switch scope {
        case .workspaces:
            workspaces
        case .notifications:
            notifications
        }
    }

    private func setNativeSearchText(_ value: String, for scope: MobilePrimarySearchScope) {
        let value = MobileSearchQueryBounds.boundedEditingText(value).value
        switch scope {
        case .workspaces:
            guard workspaceNativeSearchText != value else { return }
            workspaceNativeSearchText = value
        case .notifications:
            guard notificationNativeSearchText != value else { return }
            notificationNativeSearchText = value
        }
    }

    private func setCommittedSearchText(_ value: String, for scope: MobilePrimarySearchScope) {
        let value = MobileSearchQueryBounds.boundedEditingText(value).value
        switch scope {
        case .workspaces:
            guard workspaces != value else { return }
            workspaces = value
        case .notifications:
            guard notifications != value else { return }
            notifications = value
        }
    }

    private func normalizeCommittedSearchText(
        for scope: MobilePrimarySearchScope,
        oldValue: String
    ) {
        let normalized = MobileSearchQueryBounds.boundedEditingText(committedSearchText(for: scope))
        if normalized.didChange {
            setCommittedSearchText(normalized.value, for: scope)
        }
        if normalized.value != oldValue {
            setNativeSearchText(normalized.value, for: scope)
        }
    }

    private func commitNativeDraft(for scope: MobilePrimarySearchScope) {
        setCommittedSearchText(
            MobileSearchQueryBounds.normalizedFilterText(nativeSearchText(for: scope)).value,
            for: scope
        )
    }

    private func syncNativeSearchText(fromCommittedQueryFor scope: MobilePrimarySearchScope) {
        setNativeSearchText(committedSearchText(for: scope), for: scope)
    }

    private func beginDeactivation(for scope: MobilePrimarySearchScope) {
        phase = .deactivating(scope)
        syncNativeSearchText(fromCommittedQueryFor: scope)
    }

    private func activate(scope: MobilePrimarySearchScope) {
        if phase != .active(scope) || !isPresented {
            activationGeneration &+= 1
        }
        self.scope = scope
        isPresented = true
        phase = .active(scope)
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
