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
    private var platformSearchingScope: MobilePrimarySearchScope?
    private var workspaceNativeSearchText = ""
    private var notificationNativeSearchText = ""
    private var pendingRestoredQueryScope: MobilePrimarySearchScope?
    private var swallowOneEmptyEditScope: MobilePrimarySearchScope?
    private let searchQueryBounds = MobileSearchQueryBounds()

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

    /// Re-presents the search field carrying the scope's committed query, for
    /// restoring a session that was ended around a pushed detail.
    ///
    /// SwiftUI only pushes the bound text into the platform field when it
    /// observes the binding change, and the fresh field of a programmatic
    /// presentation starts (and self-clears to) empty. So the field presents
    /// with an EMPTY binding (both sides agree), the destination keeps
    /// filtering by the committed query for the duration, and the query is
    /// injected as an observable binding change once the platform reports the
    /// search active — with a one-shot guard for the field's late stale clear.
    func restorePresentation(for scope: MobilePrimarySearchScope) {
        self.scope = scope
        let committed = committedSearchText(for: scope)
        pendingRestoredQueryScope = committed.isEmpty ? nil : scope
        setPresentation(true)
        if pendingRestoredQueryScope != nil {
            setNativeSearchText("", for: scope)
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
            platformSearchingScope = scope
            if pendingRestoredQueryScope == scope {
                // The platform search is live: inject the restored query as a
                // fresh binding change so SwiftUI pushes it into the field.
                pendingRestoredQueryScope = nil
                syncNativeSearchText(fromCommittedQueryFor: scope)
                swallowOneEmptyEditScope = scope
            }
        } else if phase == .active(scope) {
            guard platformSearchingScope == scope else { return }
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
        if pendingRestoredQueryScope == scope, !value.isEmpty {
            // The user typed before the restoration completed; their edit wins.
            pendingRestoredQueryScope = nil
        }
        if swallowOneEmptyEditScope == scope {
            swallowOneEmptyEditScope = nil
            if value.isEmpty {
                // The presenting field's stale self-clear arriving after the
                // restored query was injected; the injected query stands.
                syncNativeSearchText(fromCommittedQueryFor: scope)
                return
            }
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
            // Mid-restoration the binding is deliberately empty; the results
            // keep filtering by the query being restored.
            if pendingRestoredQueryScope == scope {
                return committedSearchText(for: scope)
            }
            return nativeSearchText(for: scope)
        }
        return committedSearchText(for: scope)
    }

    func notificationFeedNavigationRoute(
        selectedTab: MobilePrimaryTab
    ) -> MobilePrimaryNotificationNavigationRoute {
        if selectedTab == .search {
            return scope == .notifications
                ? .mountedNotificationSearch
                : .notificationTabAfterSearchDismissal
        }
        if isPresented {
            return .notificationTabAfterSearchDismissal
        }
        return .mountedNotificationTab
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
        let value = searchQueryBounds.boundedEditingText(value).value
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
        let value = searchQueryBounds.boundedEditingText(value).value
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
        let normalized = searchQueryBounds.boundedEditingText(committedSearchText(for: scope))
        if normalized.didChange {
            setCommittedSearchText(normalized.value, for: scope)
        }
        if normalized.value != oldValue {
            setNativeSearchText(normalized.value, for: scope)
        }
    }

    private func commitNativeDraft(for scope: MobilePrimarySearchScope) {
        setCommittedSearchText(
            searchQueryBounds.normalizedFilterText(nativeSearchText(for: scope)).value,
            for: scope
        )
    }

    private func syncNativeSearchText(fromCommittedQueryFor scope: MobilePrimarySearchScope) {
        setNativeSearchText(committedSearchText(for: scope), for: scope)
    }

    private func beginDeactivation(for scope: MobilePrimarySearchScope) {
        phase = .deactivating(scope)
        platformSearchingScope = nil
        pendingRestoredQueryScope = nil
        swallowOneEmptyEditScope = nil
        syncNativeSearchText(fromCommittedQueryFor: scope)
    }

    private func activate(scope: MobilePrimarySearchScope) {
        let startsNewActivation = phase != .active(scope) || !isPresented
        if startsNewActivation {
            activationGeneration &+= 1
            platformSearchingScope = nil
        }
        self.scope = scope
        isPresented = true
        phase = .active(scope)
        if startsNewActivation {
            syncNativeSearchText(fromCommittedQueryFor: scope)
        }
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
