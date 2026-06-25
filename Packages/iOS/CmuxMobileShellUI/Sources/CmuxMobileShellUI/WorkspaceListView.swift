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
    var unreadIndicatorLeftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift
    var profilePictureLeftShift: Double = MobileDisplaySettings.defaultProfilePictureLeftShift
    var profilePictureSize: Double = MobileDisplaySettings.defaultProfilePictureSize
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
    /// Manual reconnect for the offline status row. `nil` in previews.
    var reconnect: (() -> Void)?
    /// Present the add-device (pairing) flow from the Computers screen. `nil`
    /// hides the add affordance there.
    var showAddDevice: (() -> Void)?
    /// The shell store, forwarded to Settings to drive the multi-Mac switcher.
    /// `nil` in previews.
    var store: CMUXMobileShellStore?

    /// Machines present in the (aggregated) workspace list, for the filter's
    /// machine multi-select. Single-machine yields no machine section. Names
    /// come from the device tree (registry or paired Macs), falling back to id.
    private var filterMachines: [WorkspaceFilterMachine] {
        let ids = MobileWorkspaceListFilter.machineIDs(in: workspaces)
        guard ids.count > 1 else { return [] }
        let names = macDisplayNamesByID()
        return ids.map { WorkspaceFilterMachine(id: $0, name: names[$0] ?? fallbackMacPickerName) }
    }
    /// Optional: rename a workspace on the Mac. When present, each row offers a
    /// Rename context-menu action.
    var renameWorkspace: ((MobileWorkspacePreview.ID, String) -> Void)?
    /// Optional: pin/unpin a workspace on the Mac. When present, each row offers
    /// a Pin/Unpin context-menu action and pinned workspaces sort to the top.
    var setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    /// Optional: mark a workspace read/unread on the Mac. When present, each
    /// row offers a leading swipe action.
    var setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    /// Optional: close a workspace on the Mac. When present, each row offers a
    /// destructive Delete context-menu and swipe action.
    var closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)?
    /// Optional: collapse/expand a group on the Mac. When present, group headers
    /// toggle their section; when `nil` the chevron renders as a passive
    /// disclosure indicator. Grouped rendering itself is gated on `groups`, not
    /// on this closure.
    var toggleGroupCollapsed: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?
    /// Whether the root scene is still trying the first stored-Mac reconnect.
    /// The list stays visible and owns this loading state so startup never gets
    /// trapped behind a full-screen spinner.
    var isInitialConnectionLoading = false
    /// Whether the first stored-Mac reconnect exceeded the root-scene deadline.
    /// The status row then exposes recovery actions instead of staying silent.
    var initialConnectionTimedOut = false
    var retryInitialConnection: (() -> Void)?
    @State private var searchText = ""
    @State private var showingShortcutsSettings = false
    @State private var showingSettings = false
    @State private var showingDeviceTree = false
    /// The active row filter (All / Unread), shared-model state behind the
    /// toolbar ``WorkspaceListFilterMenu``. Session-transient like a search.
    @State private var filter: MobileWorkspaceListFilter = .all
    /// Which Mac's workspaces the list is focused on. Starts at "All Macs" so
    /// aggregation is explicit in the title picker and can be narrowed from
    /// there.
    @State private var macSelection: WorkspaceMacSelection = .all
    /// The workspace whose destructive close action is awaiting confirmation.
    /// Stored at list scope so reusable rows do not own transient presentation
    /// state while `List` is recycling swipe-action rows.
    @State private var workspacePendingCloseID: MobileWorkspacePreview.ID?

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
    /// flattens the same way, for the same reason. A single-Mac picker scope
    /// still renders groups; "All Macs" flattens because group ids are Mac-local.
    private var rendersGroupedSections: Bool {
        !groups.isEmpty
            && trimmedQuery.isEmpty
            && filter.readState == .all
            && visibleMacSelection != .all
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
            activeFilter.matches(workspace)
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
        MobileWorkspaceListItem.items(workspaces: groupedWorkspaces, groups: groups)
    }

    private var groupedWorkspaces: [MobileWorkspacePreview] {
        workspaces.filter { activeFilter.matches($0) }
    }

    private var activeFilter: MobileWorkspaceListFilter {
        var active = filter
        switch visibleMacSelection {
        case .automatic:
            break
        case .all:
            active.machines.removeAll()
        case .machine(let id):
            active.machines = Set([id])
        }
        return active
    }

    private var visibleMacSelection: WorkspaceMacSelection {
        let machineIDs = Set(macPickerMachines.map(\.id))
        switch macSelection {
        case .automatic:
            return .all
        case .machine(let id):
            return machineIDs.contains(id) ? .machine(id) : .all
        case .all:
            return .all
        }
    }

    private var macPickerMachines: [WorkspaceFilterMachine] {
        let names = macDisplayNamesByID()
        var ids = Set(MobileWorkspaceListFilter.machineIDs(in: workspaces))
        if let connectedID = store?.connectedMacDeviceID {
            ids.insert(connectedID)
        }
        return ids
            .map { WorkspaceFilterMachine(id: $0, name: names[$0] ?? fallbackMacPickerName) }
            .sorted { lhs, rhs in lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
    }

    private var fallbackMacPickerName: String {
        L10n.string("mobile.workspaces.macPicker.label", defaultValue: "Mac")
    }

    private func macDisplayNamesByID() -> [String: String] {
        var names: [String: String] = [:]
        for workspace in workspaces {
            guard let id = workspace.macDeviceID,
                  let name = workspace.macDisplayName,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            names[id] = name
        }
        for device in store?.deviceTreeDevices ?? [] {
            if let name = device.displayName, !name.isEmpty {
                names[device.deviceId] = name
            }
        }
        for mac in store?.pairedMacs ?? [] {
            names[mac.macDeviceID] = mac.resolvedName
        }
        return names
    }

    var body: some View {
        List {
            if let store, showsConnectionRecoveryRow {
                Section {
                    MobileConnectionRecoveryBanner(
                        connectionRequiresReauth: store.connectionRequiresReauth,
                        connectionRecoveryFailed: store.connectionRecoveryFailed,
                        isRecoveringConnection: store.isRecoveringConnection,
                        connectionError: store.connectionError,
                        retry: { store.retryMobileConnection() },
                        signOut: signOut,
                        rendersInline: true
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowSeparator(.hidden)
                }
            }
            if connectionStatus != .connected {
                Section {
                    MobileMacConnectionStatusRow(
                        host: host,
                        status: connectionStatus,
                        showsSpinner: isInitialConnectionLoading,
                        titleOverride: initialConnectionTimedOut
                            ? L10n.string("mobile.loading.timeout.title", defaultValue: "Still loading")
                            : nil,
                        descriptionOverride: initialConnectionTimedOut
                            ? L10n.string(
                                "mobile.loading.timeout.message",
                                defaultValue: "cmux could not finish restoring this session. Check that the Mac app is running, then retry or add this Mac again."
                            )
                            : nil,
                        retry: initialConnectionTimedOut ? retryInitialConnection : nil,
                        addDevice: initialConnectionTimedOut ? showAddDevice : nil,
                        reconnect: reconnect
                    )
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowSeparator(.hidden)
                }
            }
            Section {
                if rendersGroupedSections {
                    groupedRows
                } else if activeFilter.isActive && trimmedQuery.isEmpty && filteredWorkspaces.isEmpty && !workspaces.isEmpty {
                    // The filter alone (not the Mac, and not a search query)
                    // emptied the list; offer the way back. While searching, the
                    // standard empty search result is shown instead, since "Show
                    // All" would not resolve a query that matches nothing.
                    WorkspaceListFilterEmptyRow(filter: activeFilter) {
                        filter = .all
                        macSelection = .all
                    }
                        .listRowSeparator(.hidden)
                } else {
                    flatRows
                }
            }
        }
        .listStyle(.plain)
        .workspaceListRefreshable(refresh)
        .onChange(of: MobileWorkspaceListFilter.machineIDs(in: workspaces)) { _, present in
            // Drop machine filters whose Mac left the aggregated list (a secondary
            // Mac disconnected, or the list fell below two machines so the filter
            // menu's machine section hid). Otherwise a stale machine id rejects
            // every row and strands the user on a blank list with no visible
            // control to clear the filter.
            filter.pruneMachines(notIn: present)
        }
        .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
        .mobileInlineNavigationTitle()
        .searchable(text: $searchText)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                settingsMenu
            }
            ToolbarItem(placement: .principal) {
                macTitlePicker
            }
            if store != nil {
                ToolbarItem(placement: .topBarLeading) {
                    devicesButton
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                WorkspaceListFilterMenu(filter: $filter, machines: [])
                if canCreateWorkspace {
                    newWorkspaceButton
                }
            }
            #else
            ToolbarItemGroup {
                WorkspaceListFilterMenu(filter: $filter, machines: filterMachines)
                if canCreateWorkspace {
                    newWorkspaceButton
                }
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
                DeviceTreeView(store: store, selectWorkspace: selectWorkspace, showAddDevice: showAddDevice)
            }
        }
        #endif
    }

    private var showsConnectionRecoveryRow: Bool {
        guard let store else { return false }
        return store.connectionRequiresReauth
            || store.connectionRecoveryFailed
            || store.isRecoveringConnection
    }

    private var canCreateWorkspace: Bool {
        connectionStatus == .connected
    }

    #if os(iOS)
    private var macTitlePickerTitle: String {
        switch visibleMacSelection {
        case .all, .automatic:
            L10n.string("mobile.workspaces.macPicker.allMacs", defaultValue: "All Macs")
        case .machine(let id):
            macPickerMachines.first { $0.id == id }?.name ?? fallbackMacPickerName
        }
    }

    private var macTitlePicker: some View {
        Menu {
            Button {
                macSelection = .all
            } label: {
                macMenuItemLabel(
                    title: L10n.string("mobile.workspaces.macPicker.allMacs", defaultValue: "All Macs"),
                    isSelected: visibleMacSelection == .all
                )
            }
            ForEach(macPickerMachines) { machine in
                Button {
                    macSelection = .machine(machine.id)
                } label: {
                    macMenuItemLabel(
                        title: machine.name,
                        isSelected: visibleMacSelection == .machine(machine.id)
                    )
                }
            }
        } label: {
            WorkspaceMacTitlePickerLabel(title: macTitlePickerTitle)
        }
        .buttonStyle(.plain)
        .tint(.white)
        .accessibilityIdentifier("MobileWorkspaceMacPicker")
    }

    @ViewBuilder
    private func macMenuItemLabel(title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var devicesButton: some View {
        Button {
            showingDeviceTree = true
        } label: {
            Image(systemName: "desktopcomputer")
        }
        .accessibilityLabel(L10n.string("mobile.computers.title", defaultValue: "Computers"))
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
                    toggleCollapsed: toggleGroupCollapsed,
                    unreadIndicatorLeftShift: unreadIndicatorLeftShift
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
        let capabilities = workspace.actionCapabilities
        WorkspaceNavigationRow(
            workspace: workspace,
            connectionStatus: workspace.macConnectionStatus ?? connectionStatus,
            isSelected: navigationStyle == .sidebar && selectedWorkspaceID == workspace.id,
            navigationStyle: navigationStyle,
            wrapWorkspaceTitles: wrapWorkspaceTitles,
            previewLineLimit: previewLineLimit,
            unreadIndicatorLeftShift: unreadIndicatorLeftShift,
            profilePictureLeftShift: profilePictureLeftShift,
            profilePictureSize: profilePictureSize,
            selectWorkspace: selectWorkspace,
            renameWorkspace: capabilities.supportsWorkspaceActions ? renameWorkspace : nil,
            setPinned: capabilities.supportsWorkspaceActions ? setPinned : nil,
            setUnread: capabilities.supportsReadStateActions ? setUnread : nil,
            closeWorkspace: capabilities.supportsCloseActions ? requestWorkspaceClose : nil,
            isConfirmingClose: closeConfirmationBinding(for: workspace.id),
            confirmCloseWorkspace: capabilities.supportsCloseActions && closeWorkspace != nil ? { _ in
                confirmCloseWorkspace()
            } : nil
        )
        .listRowInsets(EdgeInsets(top: 4, leading: indented ? 32 : 12, bottom: 4, trailing: 12))
        .listRowSeparator(.hidden)
    }

    private var newWorkspaceButton: some View {
        Button {
            guard canCreateWorkspace else { return }
            createWorkspace()
        } label: {
            Image(systemName: "plus")
        }
        .disabled(!canCreateWorkspace)
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

    private var requestWorkspaceClose: ((MobileWorkspacePreview.ID) -> Void)? {
        guard closeWorkspace != nil else {
            return nil
        }
        return { workspaceID in
            workspacePendingCloseID = workspaceID
        }
    }

    private func closeConfirmationBinding(for workspaceID: MobileWorkspacePreview.ID) -> Binding<Bool> {
        Binding(
            get: { workspacePendingCloseID == workspaceID },
            set: { isPresented in
                if isPresented {
                    workspacePendingCloseID = workspaceID
                } else if workspacePendingCloseID == workspaceID {
                    workspacePendingCloseID = nil
                }
            }
        )
    }

    private func confirmCloseWorkspace() {
        guard let workspaceID = workspacePendingCloseID else {
            return
        }
        workspacePendingCloseID = nil
        closeWorkspace?(workspaceID)
    }
}

#if os(iOS)
private struct WorkspaceMacTitlePickerLabel: View {
    private static let titleWidth: CGFloat = 165

    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .hidden()
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)
                .layoutPriority(1)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
                .accessibilityHidden(true)
        }
        .font(.headline)
        .bold()
        .foregroundStyle(.white)
        .frame(width: Self.titleWidth, alignment: .center)
        .contentShape(Rectangle())
    }
}
#endif

private enum WorkspaceMacSelection: Hashable {
    case automatic
    case all
    case machine(String)
}
