import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
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
    var showsNavigationToolbar = true
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
    var canCreateWorkspace = true
    /// Which Mac's workspaces the list is focused on. Owned by the shell so
    /// every create-workspace entrypoint shares the same selected-Mac gate.
    @Binding var macSelection: WorkspaceMacSelection
    /// Switch the foreground Mac before applying a machine-scoped title-picker
    /// filter. `nil` in previews, where the picker remains a pure local filter.
    var switchMac: (@MainActor (String) async -> Bool)? = nil
    /// Cancels a title-picker switch that is still in flight. `nil` in previews,
    /// where no real foreground connection exists.
    var cancelMacSwitch: (@MainActor (_ restorePreviousOnCancel: Bool) async -> Void)? = nil
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
    var isInitialConnectionLoading = false
    var initialConnectionTimedOut = false
    var retryInitialConnection: (() -> Void)?
    @State private var searchText = ""
    @State private var showingShortcutsSettings = false
    @State private var showingSettings = false
    @State private var showingDeviceTree = false
    /// The active row filter (All / Unread), shared-model state behind the
    /// toolbar ``WorkspaceListFilterMenu``. Session-transient like a search.
    @State var filter: MobileWorkspaceListFilter = .all
    @State private var macTitlePickerSwitchTask: Task<Void, Never>?
    @State private var macTitlePickerSwitchIsCancellation = false
    @State private var macTitlePickerSwitchGeneration: UInt64 = 0
    @State private var macTitlePickerPendingSelection: WorkspaceMacSelection?
    @State private var deferredWorkspaceSelectionGeneration: UInt64 = 0
    /// Stable machine-menu content. Kept as value state so live workspace or
    /// device-tree updates that do not change the actual machine set/name
    /// snapshot do not rebuild an open native Menu. `nil` only before the first
    /// appearance callback, when the body can still display the live snapshot
    /// without resetting an already-open menu.
    @State var machineSnapshots: WorkspaceMachineSnapshots?
    /// The workspace whose destructive close action is awaiting confirmation.
    /// Stored at list scope so reusable rows do not own transient presentation
    /// state while `List` is recycling swipe-action rows.
    @State private var workspacePendingCloseID: MobileWorkspacePreview.ID?

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var deferredWorkspaceSelectionIdentity: [String] {
        var identity = [
            "host:\(host)",
            "mac:\(store?.connectedMacDeviceID ?? "")",
        ]
        identity.append(contentsOf: workspaces.map {
            "workspace:\($0.id.rawValue):mac:\($0.macDeviceID ?? "")"
        })
        return identity
    }

    var currentMacTitlePickerSelection: WorkspaceMacSelection {
        macTitlePickerPendingSelection ?? visibleMacSelection
    }

    var macTitlePickerShowsProgress: Bool {
        macTitlePickerPendingSelection != nil
    }

    /// Whether the list renders grouped sections. Groups are honored whenever the
    /// Mac actually emitted group sections and the user is not searching. The
    /// gate is the payload itself, not `toggleGroupCollapsed`: a Mac that emits
    /// groups also handles collapse/expand, but the capability flag arrives via a
    /// separate `mobile.host.status` call, and a slow or failed status fetch must
    /// not flatten sections the list already has (it would only lose the chevron
    /// action). A search flattens to a single matched, pinned-first list so
    /// members can be found across groups; floating pinned members out of their
    /// group is acceptable while filtering. An active filter-menu dimension
    /// flattens the same way, for the same reason. A single-Mac picker scope
    /// still renders groups only for the foreground Mac whose group metadata is
    /// available here; "All Computers" and secondary computer selections flatten because
    /// group ids are Mac-local. Non-iOS builds keep the pre-picker behavior.
    private var rendersGroupedSections: Bool {
        !groups.isEmpty
            && trimmedQuery.isEmpty
            && filter.readState == .all
            && filter.machines.isEmpty
            && canRenderGroupsForSelection
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
        let currentFilter = activeFilter
        let matches = workspaces.filter { workspace in
            currentFilter.matches(workspace)
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
        let currentFilter = activeFilter
        return workspaces.filter { currentFilter.matches($0) }
    }

    var body: some View {
        let currentMachineSnapshots = liveMachineSnapshots
        let currentVisibleMacSelection = visibleMacSelection
        let currentFilterMenuPresentMachineIDs = filterMenuPresentMachineIDs
        let displayedMachineSnapshots = machineSnapshots ?? currentMachineSnapshots
        let displayedFilterMachines = filterMenuMachines(
            machineSnapshots: displayedMachineSnapshots,
            visibleSelection: currentVisibleMacSelection
        )
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
                                defaultValue: "cmux could not finish restoring this session. Check that the selected cmux build is running, then retry or add this computer again."
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
        .onChange(of: currentFilterMenuPresentMachineIDs) { _, present in
            // Drop machine filters whose Mac left the aggregated list (a secondary
            // Mac disconnected, or the list fell below two machines so the filter
            // menu's machine section hid). Otherwise a stale machine id rejects
            // every row and strands the user on a blank list with no visible
            // control to clear the filter.
            filter.pruneMachinesForFilterMenu(presentMachineIDs: present)
        }
        .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
        .mobileInlineNavigationTitle()
        .searchable(text: $searchText)
        .toolbar {
            #if os(iOS)
            ToolbarItem(id: "workspace-list-settings", placement: .topBarLeading) {
                if showsNavigationToolbar {
                    settingsMenu
                }
            }
            ToolbarItem(id: "workspace-list-title", placement: .principal) {
                if showsNavigationToolbar {
                    macTitlePicker(machineSnapshots: displayedMachineSnapshots)
                }
            }
            ToolbarItem(id: "workspace-list-devices", placement: .topBarLeading) {
                if showsNavigationToolbar && showsDevicesButton {
                    devicesButton
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if showsNavigationToolbar {
                    WorkspaceListFilterMenu(filter: $filter, machines: displayedFilterMachines)
                    if canCreateWorkspace {
                        newWorkspaceButton
                    }
                }
            }
            #else
            ToolbarItemGroup {
                WorkspaceListFilterMenu(filter: $filter, machines: displayedFilterMachines)
                if canCreateWorkspace {
                    newWorkspaceButton
                }
            }
            #endif
        }
        .accessibilityIdentifier("MobileWorkspaceList")
        .onDisappear {
            invalidateDeferredWorkspaceSelection()
            cancelMacTitlePickerSwitch()
        }
        .onAppear {
            updateMachineSnapshots(currentMachineSnapshots)
            filter.pruneMachinesForFilterMenu(visibleMacSelection: currentVisibleMacSelection)
        }
        .onChange(of: currentMachineSnapshots) { _, snapshots in
            updateMachineSnapshots(snapshots)
        }
        .onChange(of: deferredWorkspaceSelectionIdentity) { _, _ in
            invalidateDeferredWorkspaceSelection()
        }
        .onChange(of: currentVisibleMacSelection) { _, selection in
            filter.pruneMachinesForFilterMenu(visibleMacSelection: selection)
        }
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
                DeviceTreeView(
                    store: store,
                    selectWorkspace: { id in _ = selectWorkspaceFromList(id) },
                    showAddDevice: showAddDevice
                )
            }
        }
        #endif
    }

    #if os(iOS)
    @discardableResult
    func handleMacTitlePickerSelection(_ selection: WorkspaceMacSelection) -> Task<Void, Never>? {
        let startsMachineSwitch: Bool
        if case .machine(let id) = selection {
            startsMachineSwitch = shouldSwitchForMacTitlePickerMachine(id)
        } else {
            startsMachineSwitch = false
        }
        let cancelTask = cancelMacTitlePickerSwitch(
            restorePreviousOnCancel: true,
            cancelStoreSwitch: !startsMachineSwitch
        )
        guard startsMachineSwitch else {
            macTitlePickerPendingSelection = nil
            macSelection = selection
            return nil
        }
        macTitlePickerSwitchGeneration &+= 1
        let generation = macTitlePickerSwitchGeneration
        macTitlePickerPendingSelection = selection
        let task = Task { @MainActor in
            defer {
                if macTitlePickerSwitchGeneration == generation {
                    macTitlePickerSwitchTask = nil
                    macTitlePickerSwitchIsCancellation = false
                }
            }
            await cancelTask?.value
            await applyMacTitlePickerSelection(selection, switchGeneration: generation)
        }
        macTitlePickerSwitchTask = task
        macTitlePickerSwitchIsCancellation = false
        return task
    }

    private func shouldSwitchForMacTitlePickerMachine(_ id: String) -> Bool {
        guard switchMac != nil, let store else { return false }
        let scope = macSelectionScope
        let targetIDs = scope.aliasIndex.filterMachineIDs(for: id)
        if !scope.foregroundMachineIDs.isDisjoint(with: targetIDs) {
            return false
        }
        return store.displayPairedMacs.contains { mac in
            let pairedMacIDs = scope.aliasIndex.filterMachineIDs(for: mac.macDeviceID)
            return !pairedMacIDs.isDisjoint(with: targetIDs)
        }
    }

    @discardableResult
    func cancelMacTitlePickerSwitch(
        restorePreviousOnCancel: Bool = true,
        cancelStoreSwitch: Bool = true
    ) -> Task<Void, Never>? {
        let pendingSwitchTask = macTitlePickerSwitchTask
        let pendingSwitchIsCancellation = pendingSwitchTask != nil && macTitlePickerSwitchIsCancellation
        if pendingSwitchIsCancellation {
            return pendingSwitchTask
        }
        if pendingSwitchTask != nil {
            pendingSwitchTask?.cancel()
        }
        macTitlePickerSwitchTask = nil
        macTitlePickerSwitchIsCancellation = false
        macTitlePickerPendingSelection = nil
        macTitlePickerSwitchGeneration &+= 1
        let generation = macTitlePickerSwitchGeneration
        guard pendingSwitchTask != nil else { return nil }
        guard cancelStoreSwitch else { return nil }
        let cancelMacSwitch = cancelMacSwitch
        let task = Task { @MainActor in
            defer {
                if macTitlePickerSwitchGeneration == generation {
                    macTitlePickerSwitchTask = nil
                    macTitlePickerSwitchIsCancellation = false
                }
            }
            await cancelMacSwitch?(restorePreviousOnCancel)
        }
        macTitlePickerSwitchTask = task
        macTitlePickerSwitchIsCancellation = true
        return task
    }

    @MainActor
    func applyMacTitlePickerSelection(
        _ selection: WorkspaceMacSelection,
        switchGeneration: UInt64? = nil
    ) async {
        func isCurrentSwitchRequest() -> Bool {
            guard !Task.isCancelled else { return false }
            guard let switchGeneration else { return true }
            return macTitlePickerSwitchGeneration == switchGeneration
        }

        switch selection {
        case .all, .automatic:
            guard isCurrentSwitchRequest() else { return }
            macTitlePickerPendingSelection = nil
            macSelection = selection
        case .machine(let id):
            guard isCurrentSwitchRequest() else { return }
            guard shouldSwitchForMacTitlePickerMachine(id), let switchMac else {
                macTitlePickerPendingSelection = nil
                macSelection = selection
                return
            }
            let switched = await switchMac(id)
            guard isCurrentSwitchRequest() else { return }
            macTitlePickerPendingSelection = nil
            guard switched else { return }
            macSelection = .machine(id)
        }
    }
    #endif

    private var showsConnectionRecoveryRow: Bool {
        guard let store else { return false }
        return store.connectionRequiresReauth
            || store.connectionRecoveryFailed
            || store.isRecoveringConnection
    }

    private func updateMachineSnapshots(_ snapshots: WorkspaceMachineSnapshots) {
        if machineSnapshots != snapshots {
            machineSnapshots = snapshots
        }
    }

    #if os(iOS)
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
                    selectWorkspace: { id in _ = selectWorkspaceFromList(id) },
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
            selectWorkspace: { id in _ = selectWorkspaceFromList(id) },
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
            guard canCreateWorkspaceForMacSelection else { return }
            createWorkspace()
        } label: {
            Image(systemName: "plus")
        }
        .disabled(!canCreateWorkspaceForMacSelection)
        .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
        .accessibilityIdentifier("MobileNewWorkspaceButton")
    }

    @discardableResult
    func prepareWorkspaceSelectionFromList() -> Task<Void, Never>? {
        #if os(iOS)
        return cancelMacTitlePickerSwitch()
        #else
        return nil
        #endif
    }

    @discardableResult
    func selectWorkspaceFromList(_ id: MobileWorkspacePreview.ID) -> Task<Void, Never>? {
        invalidateDeferredWorkspaceSelection()
        let selectionGeneration = deferredWorkspaceSelectionGeneration
        guard let cancelTask = prepareWorkspaceSelectionFromList() else {
            selectWorkspace(id)
            return nil
        }
        let task = Task { @MainActor in
            await cancelTask.value
            guard !Task.isCancelled,
                  deferredWorkspaceSelectionGeneration == selectionGeneration else { return }
            selectWorkspace(id)
        }
        return task
    }

    private func invalidateDeferredWorkspaceSelection() {
        deferredWorkspaceSelectionGeneration &+= 1
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
