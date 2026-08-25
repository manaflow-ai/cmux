import CmuxMobilePairedMac
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
    /// Capability and summary snapshots mapped into immutable row values above `List`.
    var workspaceChangesCapable = false
    var workspaceChangeChipsByWorkspaceID: [String: MobileWorkspaceChangesChip] = [:]
    var macUpdateHint: MobileMacUpdateHint? = nil
    var macUpdateHintMacName: String? = nil
    var dismissMacUpdateHint: (() -> Void)? = nil
    let navigationStyle: WorkspaceNavigationStyle
    var showsNavigationToolbar = true
    /// The live shell owns the leading/center toolbar so both primary tabs share
    /// one presentation and computer selection. Standalone previews keep the
    /// self-contained toolbar by leaving this false.
    var usesExternalSharedToolbar = false
    /// Whether workspace-row titles wrap (multi-line) instead of truncating to a
    /// single line. Passed in as a value snapshot so no `@Observable` store
    /// crosses the `List` boundary.
    let wrapWorkspaceTitles: Bool
    /// How many lines each row's activity preview shows (1 or 2). Passed in as
    /// a value snapshot so no `@Observable` store crosses the `List` boundary.
    var previewLineLimit: Int = MobileDisplaySettings.defaultWorkspacePreviewLineCount
    var unreadIndicatorLeftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    let createWorkspace: () -> Void
    var createWorkspaceInGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil
    var createWorkspaceGroup: (() -> Void)? = nil
    var canCreateWorkspace = true
    /// Which Mac's workspaces the list is focused on. Owned by the shell so
    /// every create-workspace entrypoint shares the same selected-Mac gate.
    @Binding var macSelection: WorkspaceMacSelection
    /// Switch the foreground Mac app instance before applying a machine-scoped
    /// title-picker filter. `nil` in previews, where the picker remains a pure
    /// local filter.
    var switchMac: (@MainActor (String, String?) async -> Bool)? = nil
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
    var signOut: (() -> Void)?
    /// Manual reconnect for the offline status row. `nil` in previews.
    var reconnect: (() -> Void)?
    /// Whether Tailscale still needs its one-time Mac authorization.
    var tailscalePairingRequired = false
    /// Present the add-device (pairing) flow from the Computers screen. `nil`
    /// hides the add affordance there.
    var showAddDevice: (() -> Void)?
    /// Live app routes the Computers screen through the root modal owner.
    /// Standalone previews retain the local device-tree sheet.
    var showComputers: (() -> Void)? = nil
    var showPairingScanner: (() -> Void)?
    /// The shell store, forwarded to Settings to drive the multi-Mac switcher.
    /// `nil` in previews.
    var store: CMUXMobileShellStore?

    /// Optional: rename a workspace on the Mac. When present, each row offers a
    /// Rename context-menu action.
    var renameWorkspace: ((MobileWorkspacePreview.ID, String) -> Void)?
    /// Optional: edit a workspace's durable identity on the Mac. Newer hosts
    /// expose one customization sheet for name, description, color, and pin.
    var customizeWorkspace: WorkspaceCustomizationAction? = nil
    /// Optional: pin/unpin a workspace on the Mac. When present, each row offers
    /// a Pin/Unpin context-menu action and pinned workspaces sort to the top.
    var setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    /// Optional: mark a workspace read/unread on the Mac. When present, each
    /// row offers a leading swipe action.
    var setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    /// Optional: close a workspace on the Mac. When present, each row offers a
    /// destructive Delete context-menu and swipe action.
    var closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)?
    /// Optional: move a workspace to a new group/order on the Mac; enables native row drag/drop while unfiltered.
    var moveWorkspace: ((
        _ id: MobileWorkspacePreview.ID,
        _ groupID: MobileWorkspaceGroupPreview.ID?, _ beforeWorkspaceID: MobileWorkspacePreview.ID?,
        _ movesGroup: Bool
    ) async -> Bool)? = nil
    /// Optional: rename a workspace group on the Mac.
    var renameWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID, String) -> Void)? = nil
    /// Optional: pin or unpin a workspace group on the Mac.
    var setGroupPinned: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)? = nil
    /// Optional: dissolve a workspace group on the Mac, keeping its workspaces.
    var ungroupWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil
    /// Optional: delete a workspace group on the Mac, including its workspaces.
    var deleteWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil
    /// Optional: collapse/expand a group on the Mac. When present, group headers
    /// toggle their section; when `nil` the chevron renders as a passive
    /// disclosure indicator. Grouped rendering itself is gated on `groups`, not
    /// on this closure.
    var toggleGroupCollapsed: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)?
    var isInitialConnectionLoading = false
    var initialConnectionTimedOut = false
    var retryInitialConnection: (() -> Void)?
    /// How the aggregated All Computers list orders its rows. Passed as a value
    /// snapshot so no `@Observable` store crosses the `List` boundary; the
    /// device-local preference lives on the shell store.
    var workspaceSortMode: MobileWorkspaceSortMode = .automatic
    /// Persist a sort-mode choice on this device. `nil` hides the sort menu
    /// (previews and macOS fallback).
    var setWorkspaceSortMode: ((MobileWorkspaceSortMode) -> Void)? = nil
    /// The user's computer order for ``MobileWorkspaceSortMode/computerPriority``,
    /// highest first, as device-plus-build pairing ids.
    var workspaceComputerPriority: [String] = []
    /// Persist a computer order on this device.
    var setWorkspaceComputerPriority: (([String]) -> Void)? = nil
    /// Shared across the normal workspace tab and its native search
    /// presentation so filters compose with the active query.
    let filterState: WorkspaceListFilterState
    /// The query is owned by ``WorkspaceListSearchHost`` so authoritative
    /// workspace refreshes cannot recreate the native search presentation.
    var searchText = ""
    @Environment(\.mobileChildPresentationProvider) private var childPresentationProvider
    @State private var showingShortcutsSettings = false
    @State private var showingSettings = false
    /// Presents the view-options card (sort tiles + filter rows).
    @State var showingViewOptionsPopover = false
    @State private var settingsPairingScannerHandoff = SettingsPairingScannerHandoff()
    @State private var showingDeviceTree = {
        #if DEBUG
        AutoConnectMigrationUITestConfiguration.currentProcess?.initialModalHost
            == .workspaceListDeviceTree
        #else
        false
        #endif
    }()
    /// Local presenter identity remains separate from the selected changes payload.
    @State var isWorkspaceChangesPresented = false
    @State var changesSheetTarget: WorkspaceChangesSheetTarget? = nil
    @State private var macTitlePickerSwitchTask: Task<Void, Never>?
    @State private var macTitlePickerSwitchIsCancellation = false
    @State private var macTitlePickerSwitchGeneration: UInt64 = 0
    @State private var macTitlePickerPendingSelection: WorkspaceMacSelection?
    @State var deferredWorkspaceSelectionGeneration: UInt64 = 0
    /// Stable machine-menu content. Kept as value state so live workspace or
    /// device-tree updates that do not change the actual machine set/name
    /// snapshot do not rebuild an open native Menu. `nil` only before the first
    /// appearance callback, when the body can still display the live snapshot
    /// without resetting an already-open menu.
    @State var machineSnapshots: WorkspaceMachineSnapshots?
    /// The workspace whose destructive close action is awaiting confirmation.
    /// Stored at list scope so reusable rows do not own transient presentation
    /// state while `List` is recycling swipe-action rows.
    @State var workspacePendingCloseID: MobileWorkspacePreview.ID?
    /// The workspace whose UIKit context-menu rename action is presenting the
    /// list-scoped rename alert.
    @State var workspacePendingRenameID: MobileWorkspacePreview.ID?
    /// Stable text storage for the list-scoped workspace rename alert.
    @State var workspaceRenameDraft = ""
    /// The workspace whose UIKit context-menu action is presenting the shared
    /// customization sheet.
    @State var isWorkspaceCustomizationPresented = false
    @State var workspacePendingCustomizationID: MobileWorkspacePreview.ID?
    /// The group whose UIKit context-menu action is presenting the shared
    /// rename alert.
    @State var workspaceGroupPendingRenameID: MobileWorkspaceGroupPreview.ID?
    /// Stable text storage for the list-scoped group rename alert.
    @State var workspaceGroupRenameDraft = ""
    /// The group and destructive operation awaiting confirmation from a UIKit
    /// context-menu action.
    @State var workspaceGroupDestructiveRequest = WorkspaceGroupDestructiveRequestState()
    var workspaceGroupPendingDestructiveID: MobileWorkspaceGroupPreview.ID? {
        workspaceGroupDestructiveRequest.groupID
    }
    var workspaceGroupPendingDestructiveAction: WorkspaceGroupHeaderPendingDestructiveAction? {
        workspaceGroupDestructiveRequest.action
    }
    @State var optimisticFlatState = MobileWorkspaceOptimisticOrderReconciler()
    @State var optimisticGroupedState = MobileWorkspaceOptimisticOrderReconciler()
    @State private var displayedGroupedProjectionCache = WorkspaceListGroupedProjectionCache()
    @State private var authoritativeGroupedProjectionCache = WorkspaceListGroupedProjectionCache()
    /// In-flight move RPC count plus the tail of the send chain. Moves stay
    /// enabled while pending (disabling mid-gesture cancels the reorder
    /// interaction), so rapid drags can pipeline; sends are chained so the Mac
    /// applies them in UI order and the authoritative snapshot converges on
    /// the predicted optimistic order instead of racing it.
    @State var pendingWorkspaceMoveCount = 0
    @State var pendingWorkspaceMoveTask: Task<Bool, Never>?
    /// Bumped when a supersede or failure invalidates the pending chain, so
    /// queued moves computed against overruled predictions abort unsent.
    @State var workspaceMoveEpoch: UInt64 = 0

    var filter: MobileWorkspaceListFilter {
        get { filterState.filter }
        nonmutating set { filterState.filter = newValue }
    }

    /// Uses the root modal owner in the live app and local state in previews.
    func resolvedPresentation(
        for child: MobileRootPresentationState.ChildPresentation,
        fallback: Binding<Bool>
    ) -> MobileChildSheetPresentation {
        childPresentationProvider?.presentation(for: child, fallback: fallback)
            ?? MobileChildSheetPresentation(isPresented: fallback)
    }

    private var terminalShortcutsPresentation: MobileChildSheetPresentation {
        resolvedPresentation(
            for: .workspaceList(.terminalShortcutsSettings),
            fallback: $showingShortcutsSettings
        )
    }

    private var settingsPresentation: MobileChildSheetPresentation {
        resolvedPresentation(
            for: .workspaceList(.settings),
            fallback: $showingSettings
        )
    }

    private var deviceTreePresentation: MobileChildSheetPresentation {
        resolvedPresentation(
            for: .workspaceList(.deviceTree),
            fallback: $showingDeviceTree
        )
    }

    var viewOptionsPresentation: MobileChildSheetPresentation {
        resolvedPresentation(
            for: .workspaceList(.viewOptions),
            fallback: $showingViewOptionsPopover
        )
    }

    var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var deferredWorkspaceSelectionIdentity: [String] {
        var identity = [
            "host:\(host)",
            "mac:\(store?.connectedMacDeviceID ?? "")",
        ]
        identity.append(contentsOf: workspaces.map {
            "workspace:\($0.id.rawValue):mac:\($0.macDeviceID ?? ""):tag:\($0.macInstanceTag ?? "")"
        })
        return identity
    }

    var currentMacTitlePickerSelection: WorkspaceMacSelection {
        macTitlePickerPendingSelection ?? visibleMacSelection
    }

    var macTitlePickerShowsProgress: Bool {
        macTitlePickerPendingSelection != nil
    }

    /// Whether the list presents the recency sort: chosen mode `.recentActivity`
    /// while the visible scope spans computers (All Computers). A single-Mac
    /// scope keeps that Mac's own order — the sort exists to make the
    /// cross-computer order deterministic, not to rewrite one Mac's sidebar.
    var appliesRecencySort: Bool {
        guard workspaceSortMode == .recentActivity else { return false }
        switch visibleMacSelection {
        case .all, .automatic:
            return true
        case .machine:
            return false
        }
    }

    /// The sort mode the filter menu offers, or `nil` to hide the sort section:
    /// sorting is an All Computers concern, so a single-machine scope (whose
    /// order is the Mac's own sidebar order) offers none. No computer-count
    /// gate: the preference is worth setting before a second computer pairs,
    /// and a wedged or offline secondary connection must not hide the control.
    var workspaceSortMenuMode: MobileWorkspaceSortMode? {
        guard setWorkspaceSortMode != nil else { return nil }
        switch visibleMacSelection {
        case .all, .automatic:
            return workspaceSortMode
        case .machine:
            return nil
        }
    }

    /// Computers offered by the computer-order editor, one per app instance,
    /// in their effective order: stored priority first, then the list's
    /// current display order. Present computers come straight from the
    /// aggregated rows (not the filter menu's machine list, which empties
    /// below its two-machine floor and would drop a singleton or reorder the
    /// tail); paired-but-offline computers follow, keeping their slot while
    /// disconnected.
    func computerOrderSheetMachines(
        machineSnapshots: WorkspaceMachineSnapshots
    ) -> [WorkspaceFilterMachine] {
        let snapshotsByID = Dictionary(
            uniqueKeysWithValues: machineSnapshots.macPickerMachines.map { ($0.id, $0) }
        )
        var machines: [WorkspaceFilterMachine] = []
        var seenComputerIDs = Set<String>()
        for workspace in workspaces {
            guard let deviceID = workspace.macDeviceID, !deviceID.isEmpty else { continue }
            let rowID = MobilePairedMac.pairingID(
                macDeviceID: deviceID,
                instanceTag: workspace.macInstanceTag
            )
            let representativeID = machineSnapshots.representativeID(for: rowID)
            guard seenComputerIDs.insert(representativeID).inserted else { continue }
            if let snapshot = snapshotsByID[representativeID] {
                machines.append(snapshot)
                continue
            }
            let identity = MobilePairedMac.pairingIdentity(from: representativeID)
            machines.append(WorkspaceFilterMachine(
                id: representativeID,
                macDeviceID: identity.macDeviceID,
                instanceTag: identity.instanceTag,
                name: workspace.macDisplayName ?? representativeID,
                buildLabel: nil
            ))
        }
        for mac in displayPairedMacsForPicker where !mac.macDeviceID.isEmpty {
            let representativeID = machineSnapshots.representativeID(for: mac.id)
            guard seenComputerIDs.insert(representativeID).inserted else { continue }
            if let snapshot = snapshotsByID[representativeID] {
                machines.append(snapshot)
                continue
            }
            let identity = MobilePairedMac.pairingIdentity(from: representativeID)
            machines.append(WorkspaceFilterMachine(
                id: representativeID,
                macDeviceID: identity.macDeviceID,
                instanceTag: identity.instanceTag,
                name: mac.resolvedName,
                buildLabel: nil
            ))
        }
        var rank: [String: Int] = [:]
        for (index, computerID) in workspaceComputerPriority.enumerated()
            where rank[computerID] == nil {
            rank[computerID] = index
        }
        return machines.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rank[lhs.element.id]
                    ?? (lhs.element.instanceTag == nil
                        ? rank[lhs.element.macDeviceID]
                        : nil)
                    ?? Int.max
                let rhsRank = rank[rhs.element.id]
                    ?? (rhs.element.instanceTag == nil
                        ? rank[rhs.element.macDeviceID]
                        : nil)
                    ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Groups render from every available Mac payload while unfiltered. Search
    /// and explicit filters flatten the results; selecting All Computers does
    /// not discard the group structure. Recent Activity ranks whole group
    /// blocks rather than interleaving their members.
    var rendersGroupedSections: Bool {
        !groups.isEmpty
            && trimmedQuery.isEmpty
            && filter.readState == .all
            && filter.machines.isEmpty
    }

    private func matchesQuery(
        _ workspace: MobileWorkspacePreview,
        query: String,
        groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview]
    ) -> Bool {
        workspace.name.localizedCaseInsensitiveContains(query)
            || workspace.customDescription?.localizedCaseInsensitiveContains(query) == true
            || workspace.previewLine.localizedCaseInsensitiveContains(query)
            || workspace.terminals.contains { $0.name.localizedCaseInsensitiveContains(query) }
            || workspace.macDisplayName?.localizedCaseInsensitiveContains(query) == true
            || workspace.groupID.flatMap { groupsByID[$0] }?.name.localizedCaseInsensitiveContains(query) == true
    }

    /// Filtered workspaces for flat presentation, pinned first and otherwise stable.
    var filteredWorkspaces: [MobileWorkspacePreview] {
        let query = trimmedQuery
        let currentFilter = activeFilter
        let parsedMachines = MobileWorkspaceListFilter.parsedMachineEntries(
            currentFilter.machines
        )
        let matches: [MobileWorkspacePreview]
        if query.isEmpty {
            matches = workspaces.filter {
                currentFilter.matches($0, parsedMachines: parsedMachines)
            }
        } else {
            let groupLookup = groupsByID
            matches = workspaces.filter { workspace in
                currentFilter.matches(workspace, parsedMachines: parsedMachines)
                    && matchesQuery(workspace, query: query, groupsByID: groupLookup)
            }
        }
        if appliesRecencySort {
            return MobileWorkspaceRecencyOrder().displayOrder(matches)
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

    /// Grouped drawable items preserving the Mac's member order and contiguity.
    var groupedListItems: [MobileWorkspaceListItem] {
        if appliesRecencySort {
            return MobileWorkspaceRecencyOrder().groupedDisplayItems(
                groupedWorkspaces,
                groups: groups
            )
        }
        return MobileWorkspaceListItem.items(workspaces: groupedWorkspaces, groups: groups)
    }
    var groupsByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceGroupPreview] {
        Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var displayedFlatWorkspaces: [MobileWorkspacePreview] {
        optimisticFlatState.optimisticOrder?
            .materializedWorkspaces(from: filteredWorkspaces) ?? filteredWorkspaces
    }

    var displayedGroupedWorkspaces: [MobileWorkspacePreview] {
        optimisticGroupedState.optimisticOrder?
            .materializedWorkspaces(from: groupedWorkspaces) ?? groupedWorkspaces
    }

    var displayedGroupedListItems: [MobileWorkspaceListItem] {
        if appliesRecencySort {
            return MobileWorkspaceRecencyOrder().groupedDisplayItems(
                displayedGroupedWorkspaces,
                groups: groups
            )
        }
        guard optimisticGroupedState.optimisticOrder != nil else {
            return groupedListItems
        }
        return MobileWorkspaceListItem.items(
            workspaces: displayedGroupedWorkspaces,
            groups: groups
        )
    }

    var groupedWorkspaces: [MobileWorkspacePreview] {
        let currentFilter = activeFilter
        let parsedMachines = MobileWorkspaceListFilter.parsedMachineEntries(
            currentFilter.machines
        )
        return workspaces.filter {
            currentFilter.matches($0, parsedMachines: parsedMachines)
        }
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
        // Group projection is synchronous and input-keyed across body updates.
        // Keep displayed and authoritative caches separate so a pending
        // optimistic drag cannot evict the rendered projection on every pass.
        let currentGroupedWorkspaces = rendersGroupedSections
            ? groupedWorkspaces
            : []
        let currentDisplayedGroupedWorkspaces = rendersGroupedSections
            ? (optimisticGroupedState.optimisticOrder?
                .materializedWorkspaces(from: currentGroupedWorkspaces)
                ?? currentGroupedWorkspaces)
            : []
        let currentDisplayedGroupedListItems = rendersGroupedSections
            ? displayedGroupedProjectionCache.items(
                workspaces: currentDisplayedGroupedWorkspaces,
                groups: groups,
                appliesRecencySort: appliesRecencySort
            )
            : []
        let currentFilteredWorkspaceOrderKey = rendersGroupedSections
            ? []
            : filteredWorkspaceOrderKey
        // Reconciliation must observe the authoritative host order while an
        // optimistic drag is pending. Once optimism clears, the displayed and
        // authoritative projections are identical, so reuse the render snapshot.
        let currentAuthoritativeGroupedListItems = rendersGroupedSections
            ? (optimisticGroupedState.optimisticOrder == nil
                ? currentDisplayedGroupedListItems
                : authoritativeGroupedProjectionCache.items(
                    workspaces: currentGroupedWorkspaces,
                    groups: groups,
                    appliesRecencySort: appliesRecencySort
                ))
            : []
        let currentGroupedWorkspaceOrderKey = currentAuthoritativeGroupedListItems.map {
            WorkspaceListStableOrderKey(item: $0)
        }
        let currentWorkspacesByID = Dictionary(
            workspaces.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        #if os(iOS)
        let baseList = workspaceTable(
            groupedItems: currentDisplayedGroupedListItems,
            workspacesByID: currentWorkspacesByID
        )
            .modifier(WorkspaceListBarUnderlap())
        #else
        let baseList = List {
            switch connectionChrome {
            case .recoveryBanner:
                if let store {
                    Section {
                        MobileConnectionRecoveryBanner(
                            connectionRequiresReauth: store.connectionRequiresReauth,
                            connectionError: store.connectionError,
                            signOut: signOut,
                            rendersInline: true
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowSeparator(.hidden)
                    }
                }
            case .statusLine(let line):
                // On macOS there is no principal computers picker to host the
                // status line, so render it as a slim inline row instead.
                Section {
                    WorkspaceConnectionStatusLineView(line: line)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowSeparator(.hidden)
                }
            case .macStatusRow:
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
                                defaultValue: "cmux could not finish restoring this session. Check that the selected cmux build is running, then retry."
                            )
                            : disconnectedConnectionFailureDescription,
                        retry: initialConnectionTimedOut ? retryInitialConnection : nil,
                        addDevice: initialConnectionTimedOut ? showAddDevice : nil,
                        reconnect: reconnect
                    )
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowSeparator(.hidden)
                }
            case .none:
                EmptyView()
            }
            Section {
                if rendersGroupedSections {
                    groupedRows(
                        items: currentDisplayedGroupedListItems,
                        workspacesByID: currentWorkspacesByID
                    )
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
        // Let the invisible footer use its 16pt boundary height. Real rows are taller.
        .environment(\.defaultMinListRowHeight, 16)
        .workspaceListRefreshable(refresh)
        #endif
        let list = baseList
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

        workspaceListWithToolbar(
            list,
            machineSnapshots: displayedMachineSnapshots,
            filterMachines: displayedFilterMachines
        )
        .accessibilityIdentifier("MobileWorkspaceList")
        .onDisappear {
            invalidateDeferredWorkspaceSelection()
            cancelMacTitlePickerSwitch()
        }
        .onAppear {
            syncOptimisticWorkspaceOrder()
            updateMachineSnapshots(currentMachineSnapshots)
            filter.pruneMachinesForFilterMenu(visibleMacSelection: currentVisibleMacSelection)
        }
        .onChange(of: currentFilteredWorkspaceOrderKey) { _, _ in
            syncOptimisticWorkspaceOrder()
        }
        .onChange(of: currentGroupedWorkspaceOrderKey) { _, _ in
            syncOptimisticWorkspaceOrder()
        }
        .onChange(of: rendersGroupedSections) { _, _ in
            syncOptimisticWorkspaceOrder()
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
        .onChange(of: filter) { _, filter in
            store?.recordAppEvent(
                .workspaceListFilterChanged,
                count: filter.isActive ? 1 : 0
            )
        }
        #if os(iOS)
        .sheet(
            isPresented: terminalShortcutsPresentation.isPresented,
            onDismiss: terminalShortcutsPresentation.didDismiss
        ) {
            TerminalShortcutsSettingsView()
        }
        .sheet(isPresented: settingsPresentation.isPresented, onDismiss: {
            settingsPresentation.didDismiss()
            settingsPairingScannerHandoff.settingsDidDismiss(startScanner: showPairingScanner)
        }) {
            MobileSettingsView(
                connectedHostName: host,
                startPairingScanner: {
                    settingsPairingScannerHandoff.requestScannerAfterDismiss(
                        isSettingsPresented: settingsPresentation.isPresented
                    )
                },
                signOut: signOut,
                store: store
            )
        }
        // Present the device tree at the workspace-list level (a single sheet,
        // not nested under Settings), so selecting a workspace dismisses straight
        // back to the workspace shell and reveals the opened workspace rather than
        // leaving a parent sheet covering it.
        .sheet(
            isPresented: deviceTreePresentation.isPresented,
            onDismiss: deviceTreePresentation.didDismiss
        ) {
            if let store {
                DeviceTreeView(
                    store: store,
                    selectWorkspace: { id in _ = selectWorkspaceFromList(id) },
                    showAddDevice: showAddDevice
                )
            }
        }
        .workspaceRenameDialog(
            isPresented: workspaceRenameIsPresented,
            text: $workspaceRenameDraft
        ) {
            let trimmed = workspaceRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if let workspaceID = workspacePendingRenameID, !trimmed.isEmpty {
                renameWorkspace?(workspaceID, trimmed)
            }
        }
        .sheet(
            isPresented: workspaceCustomizationPresentation.isPresented,
            onDismiss: {
                workspacePendingCustomizationID = nil
                workspaceCustomizationPresentation.didDismiss()
            }
        ) {
            if let workspaceID = workspacePendingCustomizationID,
               let workspace = workspaces.first(where: { $0.id == workspaceID }) {
                WorkspaceCustomizationSheet(workspace: workspace) { initialDraft, submittedDraft in
                    await customizeWorkspace?(workspaceID, initialDraft, submittedDraft) ?? .failure()
                }
            }
        }
        .workspaceGroupRenameDialog(
            isPresented: workspaceGroupRenameIsPresented,
            text: $workspaceGroupRenameDraft
        ) { newName in
            if let groupID = workspaceGroupPendingRenameID {
                renameWorkspaceGroup?(groupID, newName)
            }
        }
        .sheet(
            isPresented: workspaceChangesPresentation.isPresented,
            onDismiss: {
                changesSheetTarget = nil
                workspaceChangesPresentation.didDismiss()
            }
        ) {
            if let target = changesSheetTarget, let store {
                WorkspaceChangesSheet(
                    store: store,
                    workspaceID: target.workspaceID,
                    workspaceTitle: target.workspaceTitle
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .confirmationDialog(
            L10n.string("mobile.workspace.delete.confirmTitle", defaultValue: "Delete Workspace?"),
            isPresented: workspaceCloseConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            if closeWorkspace != nil, let workspaceID = workspacePendingCloseID {
                Button(
                    L10n.string("mobile.workspace.delete.confirmAction", defaultValue: "Delete"),
                    role: .destructive
                ) {
                    confirmCloseWorkspace()
                }
                .accessibilityIdentifier("MobileWorkspaceDeleteConfirmButton-\(workspaceID.rawValue)")
            }
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                workspacePendingCloseID = nil
            }
        } message: {
            Text(
                L10n.string(
                    "mobile.workspace.delete.confirmMessage",
                    defaultValue: "This will close the workspace on your Mac."
                )
            )
        }
        .confirmationDialog(
            workspaceGroupDestructiveDialogTitle,
            isPresented: workspaceGroupDestructiveConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            if workspaceGroupPendingDestructiveAction == .ungroup,
               let groupID = workspaceGroupPendingDestructiveID,
               ungroupWorkspaceGroup != nil {
                Button(
                    L10n.string("mobile.workspaceGroup.ungroup.confirmAction", defaultValue: "Ungroup"),
                    role: .destructive
                ) {
                    confirmWorkspaceGroupDestructiveAction()
                }
                .accessibilityIdentifier("MobileWorkspaceGroupUngroupConfirmButton-\(groupID.rawValue)")
            }
            if workspaceGroupPendingDestructiveAction == .delete,
               let groupID = workspaceGroupPendingDestructiveID,
               deleteWorkspaceGroup != nil {
                Button(
                    L10n.string("mobile.workspaceGroup.delete.confirmAction", defaultValue: "Delete Group"),
                    role: .destructive
                ) {
                    confirmWorkspaceGroupDestructiveAction()
                }
                .accessibilityIdentifier("MobileWorkspaceGroupDeleteConfirmButton-\(groupID.rawValue)")
            }
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {
                clearWorkspaceGroupDestructiveRequest()
            }
        } message: {
            Text(workspaceGroupDestructiveDialogMessage)
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
        guard switchMac != nil, store != nil else { return false }
        return macSelectionScope.shouldSwitch(to: id)
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
            guard shouldSwitchForMacTitlePickerMachine(id),
                  let target = macSelectionScope.switchTarget(for: id),
                  let switchMac else {
                macTitlePickerPendingSelection = nil
                macSelection = selection
                return
            }
            let switched = await switchMac(target.macDeviceID, target.instanceTag)
            guard isCurrentSwitchRequest() else { return }
            macTitlePickerPendingSelection = nil
            guard switched else { return }
            macSelection = .machine(id)
        }
    }
    #endif

    var connectionChrome: WorkspaceListConnectionChrome {
        WorkspaceListConnectionChrome(
            hasStore: store != nil,
            connectionRequiresReauth: store?.connectionRequiresReauth ?? false,
            connectionRecoveryFailed: store?.connectionRecoveryFailed ?? false,
            isRecoveringConnection: store?.isRecoveringConnection ?? false,
            connectionStatus: connectionStatus,
            tailscalePairingRequired: tailscalePairingRequired,
            isInitialConnectionLoading: isInitialConnectionLoading,
            initialConnectionTimedOut: initialConnectionTimedOut,
            hasLiveTransportPath: store?.workspaceListHasLiveTransportPath ?? false
        )
    }

    /// Prefer the classified migration/reconnect failure over the generic
    /// unavailable description. Guidance stays attached to its headline so a
    /// saved legacy pairing never looks like an account or QR failure.
    private var disconnectedConnectionFailureDescription: String? {
        guard connectionStatus == .unavailable else { return nil }
        return MobileDisconnectedFailureCopy(
            error: store?.connectionError,
            guidance: store?.connectionErrorGuidance
        ).combined
    }

    private func updateMachineSnapshots(_ snapshots: WorkspaceMachineSnapshots) {
        if machineSnapshots != snapshots {
            machineSnapshots = snapshots
        }
    }

    #if os(iOS)
    var devicesButton: some View {
        Button {
            if let showComputers {
                showComputers()
            } else {
                deviceTreePresentation.present()
            }
        } label: {
            Image(systemName: "desktopcomputer")
        }
        .accessibilityLabel(L10n.string("mobile.connections.title", defaultValue: "Computers"))
        .accessibilityIdentifier("MobileWorkspaceDevicesButton")
    }
    #endif

    /// Flat presentation: pinned-first rows when groups are unavailable or while searching.
    @ViewBuilder
    private var flatRows: some View {
        let enablesReorder = enablesWorkspaceReorder
        ForEach(displayedFlatWorkspaces) { workspace in
            workspaceRow(workspace, indented: false, enablesReorder: enablesReorder)
        }
        .onMove(perform: moveFlatRows)
    }

    /// Grouped presentation: collapsible Mac-ordered group headers and nested members.
    @ViewBuilder
    private func groupedRows(
        items: [MobileWorkspaceListItem],
        workspacesByID: [MobileWorkspacePreview.ID: MobileWorkspacePreview]
    ) -> some View {
        let enablesReorder = enablesWorkspaceReorder
        let groupLookup = groupsByID
        ForEach(items, id: \.id) { item in
            switch item {
            case .groupHeader(let group, let hasUnread):
                let anchorCapabilities = groupCapabilities(
                    group,
                    workspacesByID: workspacesByID
                )
                WorkspaceGroupHeaderRow(
                    value: WorkspaceGroupHeaderRowValue(
                        group: group,
                        hasUnread: hasUnread,
                        navigationStyle: navigationStyle,
                        isAnchorSelected: navigationStyle == .sidebar
                            && selectedWorkspaceID == group.liveAnchorWorkspaceID,
                        canCreateWorkspaceInGroup: canCreateWorkspaceInGroups
                            && createWorkspaceInGroup != nil,
                        canRenameGroup: anchorCapabilities.supportsGroupActions
                            && renameWorkspaceGroup != nil,
                        canSetGroupPinned: anchorCapabilities.supportsGroupActions
                            && setGroupPinned != nil,
                        canUngroupWorkspaceGroup: (!group.isPinned || !group.isEmpty)
                            && anchorCapabilities.supportsGroupActions
                            && ungroupWorkspaceGroup != nil,
                        canDeleteWorkspaceGroup: anchorCapabilities.supportsGroupActions
                            && deleteWorkspaceGroup != nil,
                        canToggleCollapsed: toggleGroupCollapsed != nil,
                        unreadIndicatorLeftShift: unreadIndicatorLeftShift
                    ),
                    actions: WorkspaceGroupHeaderRowActions(
                        selectWorkspace: { id in _ = selectWorkspaceFromList(id) },
                        createWorkspaceInGroup: createWorkspaceInGroup,
                        renameGroup: renameWorkspaceGroup,
                        setGroupPinned: setGroupPinned,
                        ungroupWorkspaceGroup: ungroupWorkspaceGroup,
                        deleteWorkspaceGroup: deleteWorkspaceGroup,
                        toggleCollapsed: toggleGroupCollapsed
                    )
                )
                .equatable()
                // The list-wide minimum row height is lowered for the
                // invisible end-of-group spacer; interactive rows keep the
                // 44pt tap target (32 content + 6/6 insets) explicitly.
                .frame(minHeight: 32)
                .moveDisabled(
                    group.isEmpty || !(enablesReorder && anchorCapabilities.supportsMoveActions)
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowSeparator(.hidden)
            case .groupFooter(let groupID):
                WorkspaceGroupFooterRow(groupName: groupLookup[groupID]?.name)
                    .moveDisabled(true)
                    .listRowInsets(EdgeInsets(top: 0, leading: 32, bottom: 0, trailing: 12))
                    .listRowSeparator(.hidden)
            case .workspace(let workspace, let indented):
                workspaceRow(workspace, indented: indented, enablesReorder: enablesReorder)
            }
        }
        .onMove(perform: moveGroupedRows)
    }

    @ViewBuilder
    private func workspaceRow(_ workspace: MobileWorkspacePreview, indented: Bool, enablesReorder: Bool) -> some View {
        let capabilities = workspace.actionCapabilities
        let changesChip = workspaceChangesCapable
            ? workspaceChangeChipsByWorkspaceID[workspace.rpcWorkspaceID.rawValue]
            : nil
        WorkspaceNavigationRow(
            workspace: workspace,
            changesChip: changesChip,
            // Gate like the UIKit table path: chip-less rows keep .combine
            // VoiceOver behavior; only rows with a tappable chip contain.
            onOpenChanges: store == nil || (changesChip?.filesChanged ?? 0) == 0 ? nil : {
                openWorkspaceChanges(workspace)
            },
            connectionStatus: workspace.macConnectionStatus ?? connectionStatus,
            isSelected: navigationStyle == .sidebar && selectedWorkspaceID == workspace.id,
            navigationStyle: navigationStyle,
            wrapWorkspaceTitles: wrapWorkspaceTitles,
            previewLineLimit: previewLineLimit,
            unreadIndicatorLeftShift: unreadIndicatorLeftShift,
            selectWorkspace: { id in _ = selectWorkspaceFromList(id) },
            renameWorkspace: capabilities.supportsWorkspaceActions ? renameWorkspace : nil,
            requestCustomization: capabilities.supportsWorkspaceActions
                && capabilities.supportsWorkspaceMetadata ? requestWorkspaceCustomization : nil,
            setPinned: capabilities.supportsWorkspaceActions ? setPinned : nil,
            setUnread: capabilities.supportsReadStateActions ? setUnread : nil,
            groupMoveMenu: capabilities.supportsMoveActions ? {
                groupMoveMenu(for: workspace.id)
            } : nil,
            moveToGroup: capabilities.supportsMoveActions ? { id, groupID in
                joinGroupAtEnd(workspaceID: id, groupID: groupID)
            } : nil,
            closeWorkspace: capabilities.supportsCloseActions ? requestWorkspaceClose : nil,
            isConfirmingClose: closeConfirmationBinding(for: workspace.id),
            confirmCloseWorkspace: capabilities.supportsCloseActions && closeWorkspace != nil ? { _ in
                confirmCloseWorkspace()
            } : nil
        )
        .moveDisabled(!(enablesReorder && capabilities.supportsMoveActions))
        .accessibilityHint(
            enablesReorder && capabilities.supportsMoveActions
                ? L10n.string(
                    "mobile.workspace.drag.a11y",
                    defaultValue: "Drag to reorder this workspace or move it between groups."
                )
                : ""
        )
        .listRowInsets(EdgeInsets(top: 4, leading: indented ? 32 : 12, bottom: 4, trailing: 12))
        .listRowSeparator(.hidden)
    }

    func openWorkspaceChanges(_ workspace: MobileWorkspacePreview) {
        guard store != nil else { return }
        workspaceChangesPresentation.present {
            changesSheetTarget = WorkspaceChangesSheetTarget(
                workspaceID: workspace.rpcWorkspaceID.rawValue,
                workspaceTitle: workspace.name
            )
        }
    }

    private func groupCapabilities(
        _ group: MobileWorkspaceGroupPreview,
        workspacesByID: [MobileWorkspacePreview.ID: MobileWorkspacePreview]
    ) -> MobileWorkspaceActionCapabilities {
        if let anchorWorkspaceID = group.liveAnchorWorkspaceID,
           let capabilities = workspacesByID[anchorWorkspaceID]?.actionCapabilities {
            return capabilities
        }
        let owner = workspacesByID.values.first { workspace in
            CmxMacAppInstanceIdentity(
                macDeviceID: group.macDeviceID ?? "",
                instanceTag: group.macInstanceTag
            ) == CmxMacAppInstanceIdentity(
                macDeviceID: workspace.macDeviceID ?? "",
                instanceTag: workspace.macInstanceTag
            )
        }
        return owner?.actionCapabilities ?? .none
    }

    var settingsMenu: some View {
        #if os(iOS)
        // Open the full Settings page (account, terminal shortcuts,
        // notifications, paired Mac) rather than a transient menu.
        Button {
            settingsPresentation.present()
        } label: {
            MobileWorkspaceSettingsIcon()
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
        .accessibilityIdentifier("MobileWorkspaceSettingsMenu")
        #else
        Menu {
            Button {
                terminalShortcutsPresentation.present()
            } label: {
                Label(
                    L10n.string("mobile.workspaces.terminalShortcuts", defaultValue: "Terminal Shortcuts"),
                    systemImage: "keyboard"
                )
            }
            .accessibilityIdentifier("MobileWorkspaceTerminalShortcutsMenuItem")
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

/// Keeps the classified headline and its recovery guidance together anywhere
/// the disconnected shell presents a failure.
struct MobileDisconnectedFailureCopy {
    let error: String?
    let guidance: String?

    var combined: String? {
        let parts = [error, guidance].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
