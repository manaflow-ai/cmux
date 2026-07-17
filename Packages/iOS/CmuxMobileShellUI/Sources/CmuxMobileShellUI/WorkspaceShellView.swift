import CMUXMobileCore
import Foundation
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
private struct WorkspaceRootToolbarContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = WorkspaceRootToolbarSizing.maximumPickerWidth
}

extension EnvironmentValues {
    var workspaceRootToolbarContentWidth: CGFloat {
        get { self[WorkspaceRootToolbarContentWidthKey.self] }
        set { self[WorkspaceRootToolbarContentWidthKey.self] = newValue }
    }
}

private enum WorkspaceRootToolbarSizing {
    static let minimumPickerWidth: CGFloat = 98
    static let maximumPickerWidth: CGFloat = 124
    private static let nonPickerWidth: CGFloat = 277

    static func pickerWidth(for contentWidth: CGFloat) -> CGFloat {
        min(
            maximumPickerWidth,
            max(minimumPickerWidth, contentWidth - nonPickerWidth)
        )
    }
}

/// The shared root toolbar used by both primary tabs. Keeping the leading
/// controls and principal picker in one component prevents the notification
/// feed from drifting away from the workspace-list toolbar contract.
struct WorkspaceRootToolbarContent: ToolbarContent {
    @Environment(\.workspaceRootToolbarContentWidth) private var contentWidth

    let openSettings: () -> Void
    let openDevices: () -> Void
    let title: String
    let isLoading: Bool
    @Binding var selection: WorkspaceMacSelection
    let machines: [WorkspaceFilterMachine]
    let showAddDevice: (() -> Void)?

    var body: some ToolbarContent {
        ToolbarItem(id: "workspace-list-settings", placement: .topBarLeading) {
            Button(action: openSettings) {
                MobileWorkspaceSettingsIcon()
            }
            .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
            .accessibilityIdentifier("MobileWorkspaceSettingsMenu")
        }
        ToolbarItem(id: "workspace-list-title", placement: .principal) {
            WorkspaceMacTitlePicker(
                title: title,
                isLoading: isLoading,
                selection: $selection,
                machines: machines,
                showAddDevice: showAddDevice,
                labelWidth: WorkspaceRootToolbarSizing.pickerWidth(for: contentWidth)
            )
        }
        ToolbarItem(id: "workspace-list-devices", placement: .topBarLeading) {
            Button(action: openDevices) {
                Image(systemName: "desktopcomputer")
            }
            .accessibilityLabel(L10n.string("mobile.computers.title", defaultValue: "Computers"))
            .accessibilityIdentifier("MobileWorkspaceDevicesButton")
        }
    }
}
#endif

struct WorkspaceShellView: View {
    @Bindable var store: CMUXMobileShellStore
    let signOut: () -> Void
    var isInitialConnectionLoading = false
    var initialConnectionTimedOut = false
    var retryInitialConnection: (() -> Void)?
    /// Present the add-device (pairing) flow from the Computers screen. `nil`
    /// hides the add affordance.
    var showAddDevice: (() -> Void)?
    let compactNavigationPolicy = WorkspaceShellCompactNavigationPolicy()
    @Environment(MobileDisplaySettings.self) private var displaySettings
    @State var compactNavigationPath: [MobileWorkspacePreview.ID] = []
    @State var pendingCompactCreateNavigationWorkspaceIDs: Set<MobileWorkspacePreview.ID>?
    #if os(iOS)
    @State private var selectedPrimaryTab: MobilePrimaryTab = .workspaces
    @State private var notificationNavigationPath: [MobileWorkspacePreview.ID] = []
    @State private var showingRootSettings = false
    @State private var showingRootDeviceTree = false
    @State private var rootToolbarMachineSnapshots: WorkspaceMachineSnapshots?
    @State private var rootToolbarPendingSelection: WorkspaceMacSelection?
    @State private var rootToolbarSelectionTask: Task<Void, Never>?
    @State private var rootToolbarSelectionGeneration: UInt64 = 0
    #endif
    @State private var hasPresentedSplitDetail = false
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var macSelection: WorkspaceMacSelection = .all
    @State var workspaceActionToast: WorkspaceActionToastContent?
    @State private var pendingMacSwitchID: String?
    @State private var pendingMacSwitchGeneration: UInt64 = 0
    var workspaceActionToastClock: any Clock<Duration> = ContinuousClock()
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    private var usesCompactStack: Bool {
        #if os(iOS)
        MobileWorkspaceShellLayoutPolicy.usesCompactStack(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
        #else
        false
        #endif
    }

    private var listConnectionStatus: MobileMacConnectionStatus {
        if isInitialConnectionLoading || initialConnectionTimedOut {
            return .reconnecting
        }
        return store.workspaceListConnectionStatus
    }

    private var canCreateWorkspaceOnForegroundConnection: Bool {
        store.connectionState == .connected
    }

    var body: some View {
        #if os(iOS)
        GeometryReader { geometry in
            MobilePrimaryTabScaffold(
                selection: $selectedPrimaryTab,
                notificationUnreadCount: visibleNotificationFeedUnreadCount
            ) {
                workspaceTabContent
            } notifications: {
                NavigationStack(path: $notificationNavigationPath) {
                    NotificationFeedStoreView(
                        store: store,
                        items: visibleNotificationFeedItems,
                        status: visibleNotificationFeedStatus
                    )
                        .toolbar {
                            if notificationNavigationPath.isEmpty {
                                rootToolbarContent
                            }
                        }
                        .navigationDestination(for: MobileWorkspacePreview.ID.self) { workspaceID in
                            workspaceDestination(
                                for: workspaceID,
                                createWorkspace: createWorkspaceInCompactStack
                            )
                            .toolbarVisibility(.hidden, for: .tabBar)
                        }
                }
            }
            .environment(\.workspaceRootToolbarContentWidth, geometry.size.width)
            .onChange(of: store.deeplinkWorkspaceNavigationRequest) { _, request in
                guard request != nil else { return }
                consumeDeeplinkNavigationRequestIfNeeded()
            }
            .onAppear {
                updateRootToolbarMachineSnapshots(liveRootToolbarMachineSnapshots)
                consumeDeeplinkNavigationRequestIfNeeded()
            }
            .onChange(of: liveRootToolbarMachineSnapshots) { _, snapshots in
                updateRootToolbarMachineSnapshots(snapshots)
            }
            .sheet(isPresented: $showingRootSettings) {
                MobileSettingsView(
                    connectedHostName: store.connectedHostName,
                    rescanQR: { store.disconnectAndForgetActiveMac() },
                    signOut: signOut,
                    store: store
                )
            }
            .sheet(isPresented: $showingRootDeviceTree) {
                DeviceTreeView(
                    store: store,
                    selectWorkspace: { id in
                        selectedPrimaryTab = .workspaces
                        selectWorkspace(id)
                    },
                    showAddDevice: showAddDevice
                )
            }
        }
        #else
        workspaceTabContent
        .onAppear {
            consumeDeeplinkNavigationRequestIfNeeded()
        }
        #endif
    }

    private var workspaceTabContent: some View {
        ZStack(alignment: .bottom) {
            layoutContent
            if let workspaceActionToast {
                WorkspaceActionToast(
                    content: workspaceActionToast,
                    clock: workspaceActionToastClock,
                    dismiss: dismissWorkspaceActionToast
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("MobileWorkspaceActionToast")
            }
        }
    }

    private var layoutContent: some View {
        Group {
            if usesCompactStack {
                stackLayout
            } else {
                splitLayout
            }
        }
        .onChange(of: usesCompactStack) { _, isCompact in
            guard isCompact, hasPresentedSplitDetail, let selectedWorkspaceID = store.selectedWorkspaceID else {
                return
            }
            compactNavigationPath = [selectedWorkspaceID]
        }
        .accessibilityIdentifier("MobileWorkspaceShell")
    }

    private var stackLayout: some View {
        NavigationStack(path: $compactNavigationPath) {
            WorkspaceListSearchHost { searchText in
                workspaceList(navigationStyle: .push, searchText: searchText)
            }
            .toolbar {
                if compactNavigationPath.isEmpty {
                    rootToolbarContent
                }
            }
            .navigationDestination(for: MobileWorkspacePreview.ID.self) { workspaceID in
                workspaceDestination(
                    for: workspaceID,
                    createWorkspace: createWorkspaceInCompactStack,
                    backButtonConfiguration: WorkspaceBackButtonConfiguration(
                        unreadCount: unreadWorkspaceCount(excluding: workspaceID),
                        badgeContrast: .darkBackground,
                        action: popCompactStack
                    )
                )
                    #if os(iOS)
                    .toolbarVisibility(.hidden, for: .tabBar)
                    #endif
                    // Only on the pushed compact stack (where a back button
                    // exists): replace the system back button with a custom one
                    // that folds the unread-workspace count INTO the same button
                    // ("‹ 3"). Hiding the system button disables the interactive
                    // swipe-back, so re-enable it via InteractiveSwipeBackEnabler.
                    .navigationBarBackButtonHidden(true)
                    .background(InteractiveSwipeBackEnabler())
            }
        }
        .onChange(of: store.selectedWorkspaceID) { _, selectedWorkspaceID in
            if let createdPath = compactNavigationPolicy.pathForCreatedWorkspaceSelection(
                currentPath: compactNavigationPath,
                selectedWorkspaceID: selectedWorkspaceID,
                existingWorkspaceIDs: pendingCompactCreateNavigationWorkspaceIDs
            ) {
                pendingCompactCreateNavigationWorkspaceIDs = nil
                compactNavigationPath = createdPath
                autoOpenSelectedWorkspaceForSoakIfNeeded()
                return
            }
            compactNavigationPath = compactNavigationPolicy.pathForSelectionChange(
                currentPath: compactNavigationPath,
                selectedWorkspaceID: selectedWorkspaceID,
                visibleWorkspaceIDs: Set(store.workspaces.map(\.id))
            )
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
        .onChange(of: compactNavigationPath) { _, path in
            guard let selectedWorkspaceID = path.last else {
                return
            }
            pendingCompactCreateNavigationWorkspaceIDs = nil
            guard store.selectedWorkspaceID != selectedWorkspaceID else {
                return
            }
            store.selectedWorkspaceID = selectedWorkspaceID
        }
        .onChange(of: store.workspaces.map(\.id)) { _, workspaceIDs in
            compactNavigationPath = compactNavigationPolicy.pathForVisibleWorkspaceIDsChange(
                currentPath: compactNavigationPath,
                visibleWorkspaceIDs: Set(workspaceIDs),
                selectedWorkspaceID: store.selectedWorkspaceID
            )
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
        .onAppear {
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            WorkspaceListSearchHost { searchText in
                workspaceList(navigationStyle: .sidebar, searchText: searchText)
            }
            .toolbar {
                rootToolbarContent
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            workspaceDestination(
                for: store.selectedWorkspaceID,
                createWorkspace: createWorkspaceIfConnected,
                safeAreaContext: splitColumnVisibility == .detailOnly ? .fullWidth : .splitSidebarVisible
            )
            #if os(iOS)
            .toolbarVisibility(splitColumnVisibility == .detailOnly ? .hidden : .visible, for: .tabBar)
            #endif
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            hasPresentedSplitDetail = true
        }
    }

    private func workspaceList(
        navigationStyle: WorkspaceNavigationStyle,
        searchText: String
    ) -> some View {
        WorkspaceListView(
            workspaces: store.workspaces,
            groups: store.workspaceGroups,
            selectedWorkspaceID: store.selectedWorkspaceID,
            host: store.connectedHostName,
            connectionStatus: listConnectionStatus,
            macUpdateHint: store.macUpdateHint,
            macUpdateHintMacName: store.connectedHostName,
            dismissMacUpdateHint: { store.dismissMacUpdateHint() },
            navigationStyle: navigationStyle,
            showsNavigationToolbar: navigationStyle != .push || compactNavigationPath.isEmpty,
            usesExternalSharedToolbar: true,
            wrapWorkspaceTitles: displaySettings.wrapWorkspaceTitles,
            previewLineLimit: displaySettings.workspacePreviewLineCount,
            unreadIndicatorLeftShift: displaySettings.unreadIndicatorLeftShift,
            profilePictureLeftShift: displaySettings.profilePictureLeftShift,
            profilePictureSize: displaySettings.profilePictureSize,
            selectWorkspace: selectWorkspace,
            createWorkspace: navigationStyle == .push
                ? createWorkspaceInCompactStack
                : createWorkspaceIfConnected,
            createWorkspaceInGroup: navigationStyle == .push
                ? createWorkspaceInGroupInCompactStackClosure
                : createWorkspaceInGroupIfConnectedClosure,
            createWorkspaceGroup: navigationStyle == .push
                ? createWorkspaceGroupInCompactStackClosure
                : createWorkspaceGroupIfConnectedClosure,
            canCreateWorkspace: canCreateWorkspaceForMacSelection,
            macSelection: $macSelection,
            switchMac: { macDeviceID in
                await switchMacFromWorkspacePicker(macDeviceID: macDeviceID)
            },
            cancelMacSwitch: cancelMacSwitchFromWorkspacePicker,
            refresh: refreshWorkspacesClosure,
            rescanQR: { store.disconnectAndForgetActiveMac() },
            signOut: signOut,
            reconnect: reconnectClosure,
            showAddDevice: showAddDevice,
            store: store,
            renameWorkspace: renameWorkspaceClosure,
            setPinned: setWorkspacePinnedClosure,
            setUnread: setWorkspaceUnreadClosure,
            closeWorkspace: closeWorkspaceClosure,
            moveWorkspace: moveWorkspaceClosure,
            renameWorkspaceGroup: renameWorkspaceGroupClosure,
            setGroupPinned: setWorkspaceGroupPinnedClosure,
            ungroupWorkspaceGroup: ungroupWorkspaceGroupClosure,
            deleteWorkspaceGroup: deleteWorkspaceGroupClosure,
            toggleGroupCollapsed: toggleGroupCollapsedClosure,
            isInitialConnectionLoading: isInitialConnectionLoading,
            initialConnectionTimedOut: initialConnectionTimedOut,
            retryInitialConnection: retryInitialConnection,
            searchText: searchText
        )
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var rootToolbarContent: some ToolbarContent {
        WorkspaceRootToolbarContent(
            openSettings: { showingRootSettings = true },
            openDevices: { showingRootDeviceTree = true },
            title: rootToolbarTitle,
            isLoading: rootToolbarPendingSelection != nil,
            selection: rootToolbarSelection,
            machines: displayedRootToolbarMachineSnapshots.macPickerMachines,
            showAddDevice: showAddDevice
        )
    }

    private var displayedRootToolbarMachineSnapshots: WorkspaceMachineSnapshots {
        rootToolbarMachineSnapshots ?? liveRootToolbarMachineSnapshots
    }

    private var visibleNotificationFeedItems: [MobileNotificationFeedItem] {
        macSelectionScope.notificationFeedItems(from: store.notificationFeedItems)
    }

    private var visibleNotificationFeedUnreadCount: Int {
        visibleNotificationFeedItems.lazy.filter { !$0.isRead }.count
    }

    private var visibleNotificationFeedStatus: MobileNotificationFeedStatus {
        store.notificationFeedStatus(scopedTo: macSelectionScope.selectedMachineIDs)
    }

    private var liveRootToolbarMachineSnapshots: WorkspaceMachineSnapshots {
        let scope = macSelectionScope
        return WorkspaceMachineSnapshots(
            workspaces: store.workspaces,
            filterMachineIDFor: { scope.aliasIndex.representativeID(for: $0) },
            macPickerMachineIDs: scope.machineIDs,
            namesByID: rootToolbarMacDisplayNames,
            fallbackName: L10n.string("mobile.workspaces.macPicker.label", defaultValue: "Computer")
        )
    }

    private var rootToolbarMacDisplayNames: [String: String] {
        var names: [String: String] = [:]
        for workspace in store.workspaces {
            if let id = workspace.macDeviceID,
               let name = workspace.macDisplayName,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                names[id] = name
            }
        }
        for item in store.notificationFeedItems
        where !item.macDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            names[item.macDeviceID] = item.macDisplayName
        }
        for device in store.deviceTreeDevices {
            if let name = device.displayName, !name.isEmpty {
                names[device.deviceId] = name
            }
        }
        for mac in store.pairedMacs + store.displayPairedMacs {
            names[mac.macDeviceID] = mac.resolvedName
        }
        guard let buildScope = MobileIOSBuildScope.current() else { return names }
        return names.mapValues(buildScope.computerDisplayName)
    }

    private var rootToolbarVisibleSelection: WorkspaceMacSelection {
        macSelectionScope.visibleSelection
    }

    private var rootToolbarTitle: String {
        switch rootToolbarVisibleSelection {
        case .all, .automatic:
            L10n.string("mobile.workspaces.macPicker.allMacs", defaultValue: "All Computers")
        case .machine(let id):
            displayedRootToolbarMachineSnapshots.macPickerMachines.first { $0.id == id }?.name
                ?? L10n.string("mobile.workspaces.macPicker.label", defaultValue: "Computer")
        }
    }

    private var rootToolbarSelection: Binding<WorkspaceMacSelection> {
        Binding(
            get: { rootToolbarPendingSelection ?? rootToolbarVisibleSelection },
            set: { selection in
                handleRootToolbarSelection(selection)
            }
        )
    }

    private func handleRootToolbarSelection(_ selection: WorkspaceMacSelection) {
        rootToolbarSelectionGeneration &+= 1
        let generation = rootToolbarSelectionGeneration
        let previousTask = rootToolbarSelectionTask
        previousTask?.cancel()
        let startsSwitch = rootToolbarSelectionNeedsMacSwitch(selection)
        // Filtering is local and immediate. A foreground connection switch can
        // continue in parallel, but an offline Mac's retained feed must remain
        // selectable even when that switch cannot complete.
        macSelection = selection
        rootToolbarPendingSelection = startsSwitch ? selection : nil

        let task = Task { @MainActor in
            defer {
                if rootToolbarSelectionGeneration == generation {
                    rootToolbarPendingSelection = nil
                    rootToolbarSelectionTask = nil
                }
            }
            if previousTask != nil {
                await cancelMacSwitchFromWorkspacePicker(restorePreviousOnCancel: true)
            }
            guard !Task.isCancelled, rootToolbarSelectionGeneration == generation else { return }
            if case .machine(let id) = selection, startsSwitch {
                let switched = await switchMacFromWorkspacePicker(macDeviceID: id)
                guard !Task.isCancelled,
                      rootToolbarSelectionGeneration == generation,
                      switched else { return }
            }
        }
        rootToolbarSelectionTask = task
    }

    private func rootToolbarSelectionNeedsMacSwitch(_ selection: WorkspaceMacSelection) -> Bool {
        guard case .machine(let id) = selection else { return false }
        let scope = macSelectionScope
        let targetIDs = scope.aliasIndex.filterMachineIDs(for: id)
        if !scope.foregroundMachineIDs.isDisjoint(with: targetIDs) {
            return false
        }
        return store.displayPairedMacs.contains { mac in
            !scope.aliasIndex.filterMachineIDs(for: mac.macDeviceID).isDisjoint(with: targetIDs)
        }
    }

    private func updateRootToolbarMachineSnapshots(_ snapshots: WorkspaceMachineSnapshots) {
        if rootToolbarMachineSnapshots != snapshots {
            rootToolbarMachineSnapshots = snapshots
        }
    }
    #endif

    /// Apply (and clear) a pending deep-link navigation intent. On the compact
    /// stack this pushes the workspace; on the split layout the store's
    /// selection already presents the detail column, so consuming just clears
    /// the request so a later size-class change cannot replay a stale push.
    private func consumeDeeplinkNavigationRequestIfNeeded() {
        guard let request = store.deeplinkWorkspaceNavigationRequest else { return }
        guard let workspaceID = store.consumeDeeplinkWorkspaceNavigationRequest() else { return }
        #if os(iOS)
        if request.origin == .notificationFeed {
            selectedPrimaryTab = .notifications
            if notificationNavigationPath.last != workspaceID {
                notificationNavigationPath = [workspaceID]
            }
            return
        }
        selectedPrimaryTab = .workspaces
        #endif
        guard usesCompactStack else { return }
        if compactNavigationPath.last != workspaceID {
            compactNavigationPath = [workspaceID]
        }
    }

    private func selectWorkspace(_ id: MobileWorkspacePreview.ID) {
        pendingCompactCreateNavigationWorkspaceIDs = nil
        store.selectedWorkspaceID = id
        if usesCompactStack, compactNavigationPath.last != id {
            compactNavigationPath = [id]
        }
    }

    /// Pull-to-refresh closure for the workspace list. Awaits the store's real
    /// `mobile.workspace.list` re-sync so the system refresh spinner reflects the
    /// actual round-trip. Captures `store` as a local so the closure (not a store
    /// reference) is what crosses into the `List`-hosting view.
    private var refreshWorkspacesClosure: @Sendable () async -> Void {
        let store = store
        // Reconnect-or-refresh: when offline, pull-to-refresh re-attempts the saved
        // active Mac or the visible unavailable workspace owner instead of
        // no-opping, so the offline list can recover itself.
        return { await store.reconnectOrRefresh() }
    }

    /// Manual reconnect for the offline status row's Reconnect button.
    private var reconnectClosure: () -> Void {
        let store = store
        return { Task { await store.reconnectOrRefresh() } }
    }

    private var canCreateWorkspace: Bool {
        canCreateWorkspaceOnForegroundConnection
    }

    var canCreateWorkspaceForMacSelection: Bool {
        macSelectionScope.canCreateWorkspace(
            base: canCreateWorkspace,
            switchPending: pendingMacSwitchID != nil
        )
    }

    @MainActor
    private func switchMacFromWorkspacePicker(macDeviceID: String) async -> Bool {
        pendingMacSwitchGeneration &+= 1
        let generation = pendingMacSwitchGeneration
        pendingMacSwitchID = macDeviceID
        defer {
            if pendingMacSwitchGeneration == generation {
                pendingMacSwitchID = nil
            }
        }
        return await store.switchToMac(macDeviceID: macDeviceID)
    }

    @MainActor
    private func cancelMacSwitchFromWorkspacePicker(restorePreviousOnCancel: Bool) async {
        pendingMacSwitchGeneration &+= 1
        let generation = pendingMacSwitchGeneration
        let restoreTask = store.cancelPendingMacSwitch(restorePreviousOnCancel: restorePreviousOnCancel)
        if restorePreviousOnCancel, let restoreTask {
            _ = await restoreTask.value
        }
        if pendingMacSwitchGeneration == generation {
            pendingMacSwitchID = nil
        }
    }

    private var macSelectionScope: WorkspaceMacSelectionScope {
        WorkspaceMacSelectionScope(
            selection: macSelection,
            workspaces: store.workspaces,
            displayPairedMacs: store.displayPairedMacs,
            notificationFeedItems: store.notificationFeedItems,
            foregroundMacDeviceID: store.connectedMacDeviceID ?? store.activeTicket?.macDeviceID,
            aliasesFor: { store.pairedMacAliasIDs(for: $0) }
        )
    }

    private func autoOpenSelectedWorkspaceForSoakIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["CMUX_MOBILE_SOAK_OPEN_SELECTED_WORKSPACE"] == "1",
              compactNavigationPath.isEmpty,
              let selectedWorkspaceID = store.selectedWorkspaceID,
              store.workspaces.contains(where: { $0.id == selectedWorkspaceID }) else {
            return
        }
        compactNavigationPath = [selectedWorkspaceID]
        #endif
    }

    /// Count of workspaces with unread activity, excluding the one currently
    /// open (you are looking at it, so it should not count toward "waiting back
    /// in the list"). Drives the back-button unread count.
    private func unreadWorkspaceCount(excluding workspaceID: MobileWorkspacePreview.ID?) -> Int {
        store.workspaces.filter { $0.hasUnread && $0.id != workspaceID }.count
    }

    /// Pop the pushed workspace detail back to the list — the action behind the
    /// custom back button (which replaces the system one to carry the count).
    private func popCompactStack() {
        guard !compactNavigationPath.isEmpty else { return }
        compactNavigationPath.removeLast()
    }

    @ViewBuilder
    private func workspaceDestination(
        for workspaceID: MobileWorkspacePreview.ID?,
        createWorkspace: @escaping () -> Void,
        safeAreaContext: MobileTerminalSafeAreaContext = .fullWidth,
        backButtonConfiguration: WorkspaceBackButtonConfiguration? = nil
    ) -> some View {
        WorkspaceDetailContainer(
            store: store,
            workspaceID: workspaceID,
            createWorkspace: createWorkspace,
            canCreateWorkspace: canCreateWorkspaceForMacSelection,
            renameWorkspace: renameWorkspaceClosure,
            setWorkspaceUnread: setWorkspaceUnreadClosure,
            closeWorkspace: closeWorkspaceClosure,
            safeAreaContext: safeAreaContext,
            backButtonConfiguration: backButtonConfiguration,
            signOut: signOut
        )
    }
}

#if os(iOS)
/// Re-enables the interactive swipe-from-edge back gesture, which UIKit disables
/// whenever a custom leading bar button replaces the system back button (we do
/// that to fold the unread count into the back control). Owns the pop gesture's
/// delegate and only lets it begin when there is actually a screen to pop, so it
/// never fires on the root list.
/// `internal` (not `private`) so `cmuxFeatureTests` can drive
/// `GestureHostController`'s delegate decisions directly.
struct InteractiveSwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { GestureHostController() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class GestureHostController: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            navigationController?.interactivePopGestureRecognizer?.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }

        // The pushed workspace detail hosts surfaces with their own pan/scroll
        // gesture recognizers — the terminal's full-bounds scroll-mechanics
        // `UIScrollView` and the browser's `WKWebView` scroll view. Taking over
        // the navigation controller's `interactivePopGestureRecognizer` delegate
        // (above, so the custom back button can re-enable the swipe) drops
        // UIKit's built-in rule that lets the edge swipe-back coexist with scroll
        // views, so the swipe stopped popping back to the workspace list over a
        // terminal or browser (issue #6634). Allow the pop gesture to recognize
        // simultaneously with those surface gestures to restore it.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer == navigationController?.interactivePopGestureRecognizer
        }
    }
}
#endif
