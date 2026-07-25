#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The mobile app's primary destinations and transient search selection.
enum MobilePrimaryTab: Hashable {
    case workspaces
    case notifications
    case search
}

/// The searchable primary destination that owns the persistent search tab.
///
/// New primary tabs must explicitly choose whether they introduce a search
/// scope or preserve the most recent searchable destination.
enum MobilePrimarySearchScope: Equatable {
    case workspaces
    case notifications
}

enum MobilePrimarySearchPhase: Equatable {
    case inactive
    case active(MobilePrimarySearchScope)
    case deactivating(MobilePrimarySearchScope)
}

enum MobilePrimarySearchCommitPolicy {
    static func acceptsNativeEdit(
        searchPhase: MobilePrimarySearchPhase,
        isSearchPresented: Bool,
        scope: MobilePrimarySearchScope,
        value: String,
        committedQuery: String,
        suppressedEmptyCommitScope: MobilePrimarySearchScope?
    ) -> Bool {
        guard searchPhase == .active(scope), isSearchPresented else {
            return false
        }
        guard
            value.isEmpty,
            !committedQuery.isEmpty,
            suppressedEmptyCommitScope == scope
        else {
            return true
        }
        return false
    }
}

private extension MobilePrimaryTab {
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

/// Native primary navigation shared by the live shell and deterministic UI
/// fixtures. Keeping the tab construction here guarantees that previews exercise
/// the same labels, symbols, badge behavior, and selection semantics as the app.
struct MobilePrimaryTabScaffold<Workspaces: View, Notifications: View>: View {
    @Binding var selection: MobilePrimaryTab
    @Binding var workspaceSearchText: String
    @Binding var notificationSearchText: String
    @State private var searchScope: MobilePrimarySearchScope
    @State private var isSearchPresented = false
    @State private var searchPhase: MobilePrimarySearchPhase = .inactive
    @State private var workspaceNativeSearchText = ""
    @State private var notificationNativeSearchText = ""
    @State private var suppressedEmptyCommitScope: MobilePrimarySearchScope?
    let notificationUnreadCount: Int
    let workspaces: Workspaces
    let notifications: Notifications

    init(
        selection: Binding<MobilePrimaryTab>,
        workspaceSearchText: Binding<String>,
        notificationSearchText: Binding<String>,
        notificationUnreadCount: Int,
        @ViewBuilder workspaces: () -> Workspaces,
        @ViewBuilder notifications: () -> Notifications
    ) {
        _selection = selection
        _workspaceSearchText = workspaceSearchText
        _notificationSearchText = notificationSearchText
        _searchScope = State(initialValue: selection.wrappedValue.searchScope ?? .workspaces)
        self.notificationUnreadCount = notificationUnreadCount
        self.workspaces = workspaces()
        self.notifications = notifications()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            TabView(selection: tabSelection) {
                primaryTabs

                Tab(value: MobilePrimaryTab.search, role: .search) {
                    searchDestination
                }
                .accessibilityIdentifier("MobilePrimaryTabSearch")
            }
            .searchable(
                text: activeSearchText,
                isPresented: searchPresentation,
                prompt: activeSearchPrompt
            )
            .onSubmit(of: .search) {
                suppressedEmptyCommitScope = searchScope
            }
            .tabViewSearchActivation(.searchTabSelection)
            .accessibilityIdentifier("MobilePrimaryTabs")
            .onChange(of: selection, initial: true) { _, selection in
                guard let scope = selection.searchScope else { return }
                searchScope = scope
                suppressedEmptyCommitScope = nil
                syncNativeSearchText(fromCommittedQueryFor: scope)
            }
        } else {
            TabView(selection: $selection) {
                primaryTabs
            }
            .accessibilityIdentifier("MobilePrimaryTabs")
        }
    }

    private var tabSelection: Binding<MobilePrimaryTab> {
        Binding(
            get: { selection },
            set: { newValue in
                if selection == .search, newValue.searchScope != nil {
                    beginSearchDeactivation(for: searchScope)
                }
                selection = newValue
            }
        )
    }

    private var searchPresentation: Binding<Bool> {
        Binding(
            get: { isSearchPresented },
            set: { presented in
                if isSearchPresented, !presented {
                    beginSearchDeactivation(for: searchScope)
                }
                isSearchPresented = presented
                if presented {
                    searchPhase = .active(searchScope)
                    suppressedEmptyCommitScope = nil
                    syncNativeSearchText(fromCommittedQueryFor: searchScope)
                }
            }
        )
    }

    @ViewBuilder
    private var searchDestination: some View {
        switch searchScope {
        case .workspaces:
            workspaces
                .modifier(MobilePrimarySearchLifecycleModifier(
                    scope: .workspaces,
                    update: updateSearchLifecycle
                ))
        case .notifications:
            notifications
                .modifier(MobilePrimarySearchLifecycleModifier(
                    scope: .notifications,
                    update: updateSearchLifecycle
                ))
        }
    }

    private var activeSearchText: Binding<String> {
        return Binding(
            get: { nativeSearchText(for: searchScope) },
            set: { value in
                commitNativeSearchText(value, for: searchScope)
            }
        )
    }

    private var activeSearchPrompt: Text {
        switch searchScope {
        case .workspaces:
            Text(
                L10n.string(
                    "mobile.workspaces.search.placeholder",
                    defaultValue: "Search workspaces"
                )
            )
        case .notifications:
            Text(
                L10n.string(
                    "mobile.notificationFeed.search.placeholder",
                    defaultValue: "Search notifications"
                )
            )
        }
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
            workspaceSearchText
        case .notifications:
            notificationSearchText
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
            workspaceSearchText = value
        case .notifications:
            notificationSearchText = value
        }
    }

    private func syncNativeSearchText(fromCommittedQueryFor scope: MobilePrimarySearchScope) {
        setNativeSearchText(committedSearchText(for: scope), for: scope)
    }

    private func commitNativeSearchText(_ value: String, for scope: MobilePrimarySearchScope) {
        let suppressedScope = suppressedEmptyCommitScope
        if suppressedScope == scope {
            suppressedEmptyCommitScope = nil
        }
        guard MobilePrimarySearchCommitPolicy.acceptsNativeEdit(
            searchPhase: searchPhase,
            isSearchPresented: isSearchPresented,
            scope: scope,
            value: value,
            committedQuery: committedSearchText(for: scope),
            suppressedEmptyCommitScope: suppressedScope
        ) else {
            syncNativeSearchText(fromCommittedQueryFor: scope)
            return
        }
        setNativeSearchText(value, for: scope)
        setCommittedSearchText(value, for: scope)
    }

    private func updateSearchLifecycle(scope: MobilePrimarySearchScope, isSearching: Bool) {
        if isSearching {
            searchPhase = .active(scope)
            syncNativeSearchText(fromCommittedQueryFor: scope)
        } else if searchPhase == .active(scope) {
            beginSearchDeactivation(for: scope)
        }
    }

    private func beginSearchDeactivation(for scope: MobilePrimarySearchScope) {
        searchPhase = .deactivating(scope)
        suppressedEmptyCommitScope = nil
        syncNativeSearchText(fromCommittedQueryFor: scope)
    }

    @TabContentBuilder<MobilePrimaryTab>
    private var primaryTabs: some TabContent<MobilePrimaryTab> {
        Tab(value: MobilePrimaryTab.workspaces) {
            workspaces
        } label: {
            Label(
                L10n.string("mobile.tabs.workspaces", defaultValue: "Workspaces"),
                systemImage: "rectangle.stack"
            )
            .accessibilityIdentifier("MobilePrimaryTabWorkspaces")
        }

        Tab(value: MobilePrimaryTab.notifications) {
            notifications
        } label: {
            Label(
                L10n.string("mobile.tabs.notifications", defaultValue: "Notifications"),
                systemImage: "bell"
            )
            .accessibilityIdentifier("MobilePrimaryTabNotifications")
        }
        .badge(notificationUnreadCount)
    }
}

private struct MobilePrimarySearchLifecycleModifier: ViewModifier {
    @Environment(\.isSearching) private var isSearching

    let scope: MobilePrimarySearchScope
    let update: (MobilePrimarySearchScope, Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isSearching, initial: true) { _, isSearching in
                update(scope, isSearching)
            }
            .onDisappear {
                update(scope, false)
            }
    }
}
#endif
