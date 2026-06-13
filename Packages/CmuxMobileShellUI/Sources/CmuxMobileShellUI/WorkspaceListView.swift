import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct WorkspaceListView: View {
    let workspaces: [MobileWorkspacePreview]
    /// The Mac's workspace groups, in section order. Empty when the Mac reports no
    /// groups; the list then renders flat. Passed as value snapshots so no
    /// `@Observable` store crosses the `List` boundary.
    var groups: [MobileWorkspaceGroupPreview] = []
    let selectedWorkspaceID: MobileWorkspacePreview.ID?
    let host: String
    let connectionStatus: MobileMacConnectionStatus
    let navigationStyle: WorkspaceNavigationStyle
    /// Whether workspace-row titles wrap (multi-line) instead of truncating to a
    /// single line. Passed in as a value snapshot so no `@Observable` store
    /// crosses the `List` boundary.
    let wrapWorkspaceTitles: Bool
    /// How many lines each row's activity preview shows (1 or 2). Passed in as
    /// a value snapshot so no `@Observable` store crosses the `List` boundary.
    var previewLineLimit: Int = MobileDisplaySettings.defaultWorkspacePreviewLineCount
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    let createWorkspace: () -> Void
    /// Pull-to-refresh action. Awaits the real workspace-list re-sync from the
    /// paired Mac so the system refresh spinner reflects actual completion (and
    /// ends gracefully, leaving the list intact, when the Mac is offline). Passed
    /// as a closure so no `@Observable` store crosses the `List` boundary. `nil`
    /// in previews, where pull-to-refresh is hidden. `@Sendable` to match
    /// SwiftUI's `refreshable(action:)` action type under Swift 6.
    var refresh: (@Sendable () async -> Void)?
    /// Optional: when present, the toolbar shows a "settings" menu offering
    /// "Rescan QR" (disconnect + re-pair) and "Sign out". When nil (e.g.
    /// previews), the menu is hidden.
    var rescanQR: (() -> Void)?
    var signOut: (() -> Void)?
    /// The shell store, forwarded to Settings to drive the multi-Mac switcher.
    /// `nil` in previews.
    var store: CMUXMobileShellStore?
    /// Optional: rename a workspace on the Mac. When present, each row offers a
    /// Rename context-menu action.
    var renameWorkspace: ((MobileWorkspacePreview.ID, String) -> Void)?
    /// Optional: pin/unpin a workspace on the Mac. When present, each row offers
    /// a Pin/Unpin context-menu action and pinned workspaces sort to the top.
    var setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    /// Optional: collapse/expand a group on the Mac. When present, group headers
    /// toggle their section; when `nil` the chevron renders as a passive
    /// disclosure indicator. Grouped rendering itself is gated on `groups`, not
    /// on this closure.
    var toggleGroupCollapsed: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?
    @State private var searchText = ""
    @State private var showingShortcutsSettings = false
    @State private var showingSettings = false
    @State private var showingDeviceTree = false
    /// The active row filter (All / Unread), shared-model state behind the
    /// toolbar ``WorkspaceListFilterMenu``. Session-transient like a search.
    @State private var filter: MobileWorkspaceListFilter = .all

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the list renders grouped sections. Groups are honored whenever the
    /// Mac actually emitted group sections and the user is not searching. The
    /// gate is the payload itself, not `toggleGroupCollapsed`: a Mac that emits
    /// groups also handles collapse/expand, but the capability flag arrives via a
    /// separate `mobile.host.status` call, and a slow or failed status fetch must
    /// not flatten sections the list already has (it would only lose the chevron
    /// action). A search flattens to a single matched, pinned-first list so
    /// members can be found across groups; floating pinned members out of their
    /// group is acceptable while filtering. An active row filter (Unread)
    /// flattens the same way, for the same reason.
    private var rendersGroupedSections: Bool {
        !groups.isEmpty && trimmedQuery.isEmpty && !filter.isActive
    }

    private func matchesQuery(_ workspace: MobileWorkspacePreview, query: String) -> Bool {
        workspace.name.localizedCaseInsensitiveContains(query)
            || workspace.previewLine.localizedCaseInsensitiveContains(query)
            || workspace.terminals.contains { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// Workspaces after the row filter (Unread) and search filtering, pinned
    /// ones first (stable within each group so the Mac's order is otherwise
    /// preserved). Used for the flat (ungrouped, filtering, or searching)
    /// presentation.
    private var filteredWorkspaces: [MobileWorkspacePreview] {
        let query = trimmedQuery
        let matches = workspaces.filter { workspace in
            filter.matches(workspace)
                && (query.isEmpty || matchesQuery(workspace, query: query))
        }
        return matches.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isPinned != rhs.element.isPinned {
                    return lhs.element.isPinned
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Ordered drawable items for the grouped presentation. Preserves the Mac's
    /// member order and contiguity (no pinned-first flattening, which would
    /// scatter group members).
    private var groupedListItems: [MobileWorkspaceListItem] {
        MobileWorkspaceListItem.items(workspaces: workspaces, groups: groups)
    }

    var body: some View {
        List {
            if connectionStatus != .connected {
                Section {
                    MobileMacConnectionStatusRow(host: host, status: connectionStatus)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowSeparator(.hidden)
                }
            }
            Section {
                if rendersGroupedSections {
                    groupedRows
                } else if filter.isActive && trimmedQuery.isEmpty && filteredWorkspaces.isEmpty && !workspaces.isEmpty {
                    // The filter alone (not the Mac, and not a search query)
                    // emptied the list; offer the way back. While searching, the
                    // standard empty search result is shown instead, since "Show
                    // All" would not resolve a query that matches nothing.
                    WorkspaceListFilterEmptyRow(filter: filter) { filter = .all }
                        .listRowSeparator(.hidden)
                } else {
                    flatRows
                }
            }
        }
        .listStyle(.plain)
        .workspaceListRefreshable(refresh)
        .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
        .mobileInlineNavigationTitle()
        .searchable(text: $searchText)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                settingsMenu
            }
            if store != nil {
                ToolbarItem(placement: .topBarLeading) {
                    devicesButton
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                WorkspaceListFilterMenu(filter: $filter)
                newWorkspaceButton
            }
            #else
            ToolbarItemGroup {
                WorkspaceListFilterMenu(filter: $filter)
                newWorkspaceButton
            }
            #endif
        }
        .accessibilityIdentifier("MobileWorkspaceList")
        #if os(iOS)
        .sheet(isPresented: $showingShortcutsSettings) {
            TerminalShortcutsSettingsView()
        }
        .sheet(isPresented: $showingSettings) {
            MobileSettingsView(
                connectedHostName: host,
                rescanQR: rescanQR,
                signOut: signOut,
                store: store
            )
        }
        // Present the device tree at the workspace-list level (a single sheet,
        // not nested under Settings), so selecting a workspace dismisses straight
        // back to the workspace shell and reveals the opened workspace rather than
        // leaving a parent sheet covering it.
        .sheet(isPresented: $showingDeviceTree) {
            if let store {
                DeviceTreeView(store: store, selectWorkspace: selectWorkspace)
            }
        }
        #endif
    }

    #if os(iOS)
    private var devicesButton: some View {
        Button {
            showingDeviceTree = true
        } label: {
            Image(systemName: "rectangle.stack")
        }
        .accessibilityLabel(L10n.string("mobile.settings.devices", defaultValue: "Devices"))
        .accessibilityIdentifier("MobileWorkspaceDevicesButton")
    }
    #endif

    /// Flat presentation: a pinned-first list with no group headers. Used when the
    /// Mac has no groups (or lacks the capability) or while searching.
    @ViewBuilder
    private var flatRows: some View {
        ForEach(filteredWorkspaces) { workspace in
            workspaceRow(workspace, indented: false)
        }
    }

    /// Grouped presentation: collapsible group headers with their members nested
    /// underneath, mirroring the Mac sidebar. Order and contiguity follow the Mac.
    @ViewBuilder
    private var groupedRows: some View {
        ForEach(groupedListItems) { item in
            switch item {
            case .groupHeader(let group, let hasUnread):
                WorkspaceGroupHeaderRow(
                    group: group,
                    hasUnread: hasUnread,
                    navigationStyle: navigationStyle,
                    isAnchorSelected: navigationStyle == .sidebar
                        && selectedWorkspaceID == group.anchorWorkspaceID,
                    selectWorkspace: selectWorkspace,
                    toggleCollapsed: toggleGroupCollapsed
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowSeparator(.hidden)
            case .workspace(let workspace, let indented):
                workspaceRow(workspace, indented: indented)
            }
        }
    }

    @ViewBuilder
    private func workspaceRow(_ workspace: MobileWorkspacePreview, indented: Bool) -> some View {
        WorkspaceNavigationRow(
            workspace: workspace,
            connectionStatus: connectionStatus,
            isSelected: navigationStyle == .sidebar && selectedWorkspaceID == workspace.id,
            navigationStyle: navigationStyle,
            wrapWorkspaceTitles: wrapWorkspaceTitles,
            previewLineLimit: previewLineLimit,
            selectWorkspace: selectWorkspace,
            renameWorkspace: renameWorkspace,
            setPinned: setPinned
        )
        .listRowInsets(EdgeInsets(top: 4, leading: indented ? 32 : 12, bottom: 4, trailing: 12))
        .listRowSeparator(.hidden)
    }

    private var newWorkspaceButton: some View {
        Button(action: createWorkspace) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
        .accessibilityIdentifier("MobileNewWorkspaceButton")
    }

    private var settingsMenu: some View {
        #if os(iOS)
        // Open the full Settings page (account, terminal shortcuts,
        // notifications, paired Mac) rather than a transient menu.
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
        .accessibilityIdentifier("MobileWorkspaceSettingsMenu")
        #else
        Menu {
            Button {
                showingShortcutsSettings = true
            } label: {
                Label(
                    L10n.string("mobile.workspaces.terminalShortcuts", defaultValue: "Terminal Shortcuts"),
                    systemImage: "keyboard"
                )
            }
            .accessibilityIdentifier("MobileWorkspaceTerminalShortcutsMenuItem")
            if let rescanQR {
                Button {
                    rescanQR()
                } label: {
                    Label(
                        L10n.string("mobile.workspaces.rescan", defaultValue: "Rescan QR"),
                        systemImage: "qrcode.viewfinder"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceRescanQRMenuItem")
            }
            if let signOut {
                Button(role: .destructive) {
                    signOut()
                } label: {
                    Label(
                        L10n.string("mobile.signOut", defaultValue: "Sign Out"),
                        systemImage: "rectangle.portrait.and.arrow.right"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceSignOutMenuItem")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
        .accessibilityIdentifier("MobileWorkspaceSettingsMenu")
        #endif
    }
}
