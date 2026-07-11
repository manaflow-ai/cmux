import Foundation
import CmuxMobileBrowser
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
    @Environment(BrowserSurfaceStore.self) private var browserStore
    @State var compactNavigationPath: [MobileWorkspacePreview.ID] = []
    @State var pendingCompactCreateNavigationWorkspaceIDs: Set<MobileWorkspacePreview.ID>?
    @State private var hasPresentedSplitDetail = false
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showingCompactSettings = false
    @State private var showingCompactDeviceTree = false
    @State private var showingCompactWorkspaceManager = false
    @State private var macSelection: WorkspaceMacSelection = .all
    @State private var isCreatingTerminalFromSurfaceGrid = false
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
        // A notification-tap deep link must actually navigate, not just mark a
        // selection: on the compact stack an empty path ignores selection
        // changes by design (the attach-time auto-selection must not yank the
        // user off the home list), so the deep link carries an explicit
        // one-shot push intent. Consumed on change and on mount in case the
        // request landed before this view appeared.
        .onChange(of: store.deeplinkWorkspaceNavigationRequest) { _, request in
            guard request != nil else { return }
            consumeDeeplinkNavigationRequestIfNeeded()
        }
        .onAppear {
            consumeDeeplinkNavigationRequestIfNeeded()
        }
        .accessibilityIdentifier("MobileWorkspaceShell")
    }

    private var stackLayout: some View {
        NavigationStack(path: $compactNavigationPath) {
            WorkspaceSurfaceGridView(
                workspaces: store.workspaces,
                selectedWorkspaceID: compactSurfaceGridSelectedWorkspaceID,
                selectedTerminalID: store.selectedTerminalID,
                host: store.connectedHostName,
                connectionStatus: listConnectionStatus,
                canCreateWorkspace: canCreateWorkspace,
                canCreateTerminal: canCreateTerminal,
                selectWorkspace: selectWorkspaceFromSurfaceGrid,
                openTerminal: openTerminalFromSurfaceGrid,
                openBrowser: openBrowserFromSurfaceGrid,
                closeBrowser: closeBrowserFromSurfaceGrid,
                createWorkspace: createWorkspaceInCompactStack,
                createTerminal: createTerminalFromSurfaceGrid,
                refresh: refreshWorkspacesClosure,
                showSettings: { showingCompactSettings = true },
                showDevices: { showingCompactDeviceTree = true },
                showWorkspaceManager: { showingCompactWorkspaceManager = true },
                reconnect: reconnectClosure,
                isInitialConnectionLoading: isInitialConnectionLoading,
                initialConnectionTimedOut: initialConnectionTimedOut,
                retryInitialConnection: retryInitialConnection,
                showAddDevice: showAddDevice
            )
            .navigationDestination(for: MobileWorkspacePreview.ID.self) { workspaceID in
                workspaceDestination(
                    for: workspaceID,
                    createWorkspace: createWorkspaceInCompactStack,
                    canCreateWorkspaceInContext: canCreateWorkspace,
                    backButtonConfiguration: WorkspaceBackButtonConfiguration(
                        unreadCount: unreadWorkspaceCount(excluding: workspaceID),
                        badgeContrast: .darkBackground,
                        action: popCompactStack
                    )
                )
                    // Only on the pushed compact stack (where a back button
                    // exists): replace the system back button with a custom one
                    // that folds the unread-workspace count INTO the same button
                    // ("‹ 3"). Hiding the system button disables the interactive
                    // swipe-back, so re-enable it via InteractiveSwipeBackEnabler.
                    .navigationBarBackButtonHidden(true)
                    .background(InteractiveSwipeBackEnabler())
            }
        }
        .sheet(isPresented: $showingCompactSettings) {
            MobileSettingsView(
                connectedHostName: store.connectedHostName,
                rescanQR: { store.disconnectAndForgetActiveMac() },
                signOut: signOut,
                store: store
            )
        }
        .sheet(isPresented: $showingCompactDeviceTree) {
            DeviceTreeView(store: store, selectWorkspace: openWorkspaceFromDeviceTree, showAddDevice: showAddDevice)
        }
        .sheet(isPresented: $showingCompactWorkspaceManager) {
            NavigationStack {
                compactWorkspaceManager
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                                showingCompactWorkspaceManager = false
                            }
                            .accessibilityIdentifier("MobileWorkspaceManagerDoneButton")
                        }
                    }
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

    private var compactWorkspaceManager: some View {
        WorkspaceListView(
            workspaces: store.workspaces,
            groups: store.workspaceGroups,
            selectedWorkspaceID: store.selectedWorkspaceID,
            host: store.connectedHostName,
            connectionStatus: listConnectionStatus,
            navigationStyle: .sidebar,
            showsNavigationToolbar: false,
            wrapWorkspaceTitles: displaySettings.wrapWorkspaceTitles,
            previewLineLimit: displaySettings.workspacePreviewLineCount,
            unreadIndicatorLeftShift: displaySettings.unreadIndicatorLeftShift,
            profilePictureLeftShift: displaySettings.profilePictureLeftShift,
            profilePictureSize: displaySettings.profilePictureSize,
            selectWorkspace: selectWorkspaceFromSurfaceGrid,
            createWorkspace: createWorkspaceInCompactStack,
            createWorkspaceInGroup: createWorkspaceInGroupInCompactStackClosure,
            createWorkspaceGroup: createWorkspaceGroupInCompactStackClosure,
            canCreateWorkspace: canCreateWorkspaceForMacSelection,
            macSelection: $macSelection,
            switchMac: { macDeviceID in
                await switchMacFromWorkspacePicker(macDeviceID: macDeviceID)
            },
            cancelMacSwitch: cancelMacSwitchFromWorkspacePicker,
            refresh: refreshWorkspacesClosure,
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
            retryInitialConnection: retryInitialConnection
        )
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            WorkspaceListView(
                workspaces: store.workspaces,
                groups: store.workspaceGroups,
                selectedWorkspaceID: store.selectedWorkspaceID,
                host: store.connectedHostName,
                connectionStatus: listConnectionStatus,
                navigationStyle: .sidebar,
                wrapWorkspaceTitles: displaySettings.wrapWorkspaceTitles,
                previewLineLimit: displaySettings.workspacePreviewLineCount,
                unreadIndicatorLeftShift: displaySettings.unreadIndicatorLeftShift,
                profilePictureLeftShift: displaySettings.profilePictureLeftShift,
                profilePictureSize: displaySettings.profilePictureSize,
                selectWorkspace: selectWorkspace,
                createWorkspace: createWorkspaceIfConnected,
                createWorkspaceInGroup: createWorkspaceInGroupIfConnectedClosure,
                createWorkspaceGroup: createWorkspaceGroupIfConnectedClosure,
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
                retryInitialConnection: retryInitialConnection
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            workspaceDestination(
                for: store.selectedWorkspaceID,
                createWorkspace: createWorkspaceIfConnected,
                canCreateWorkspaceInContext: canCreateWorkspaceForMacSelection,
                safeAreaContext: splitColumnVisibility == .detailOnly ? .fullWidth : .splitSidebarVisible
            )
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            hasPresentedSplitDetail = true
        }
    }

    /// Apply (and clear) a pending deep-link navigation intent. On the compact
    /// stack this pushes the workspace; on the split layout the store's
    /// selection already presents the detail column, so consuming just clears
    /// the request so a later size-class change cannot replay a stale push.
    private func consumeDeeplinkNavigationRequestIfNeeded() {
        guard store.deeplinkWorkspaceNavigationRequest != nil else { return }
        guard let workspaceID = store.consumeDeeplinkWorkspaceNavigationRequest() else { return }
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

    private func selectWorkspaceFromSurfaceGrid(_ id: MobileWorkspacePreview.ID) {
        pendingCompactCreateNavigationWorkspaceIDs = nil
        store.selectedWorkspaceID = id
        compactNavigationPath = []
    }

    private func openWorkspaceFromDeviceTree(_ id: MobileWorkspacePreview.ID) {
        showingCompactDeviceTree = false
        selectWorkspace(id)
    }

    private func openTerminalFromSurfaceGrid(_ workspaceID: MobileWorkspacePreview.ID, terminalID: MobileTerminalPreview.ID) {
        pendingCompactCreateNavigationWorkspaceIDs = nil
        if let workspace = store.workspaces.first(where: { $0.id == workspaceID }) {
            browserStore.showNonBrowserSurface(for: workspace.browserSurfaceIdentity)
        }
        store.selectedWorkspaceID = workspaceID
        store.selectTerminalFromChrome(terminalID)
        compactNavigationPath = [workspaceID]
    }

    private func openBrowserFromSurfaceGrid(_ workspaceID: MobileWorkspacePreview.ID) {
        pendingCompactCreateNavigationWorkspaceIDs = nil
        store.selectedWorkspaceID = workspaceID
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        browserStore.openBrowser(for: workspace.browserSurfaceIdentity)
        compactNavigationPath = [workspaceID]
    }

    private func closeBrowserFromSurfaceGrid(_ workspaceID: MobileWorkspacePreview.ID) {
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else { return }
        browserStore.closeBrowser(for: workspace.browserSurfaceIdentity)
    }

    private func createTerminalFromSurfaceGrid(_ workspaceID: MobileWorkspacePreview.ID) {
        guard !isCreatingTerminalFromSurfaceGrid else { return }
        isCreatingTerminalFromSurfaceGrid = true
        pendingCompactCreateNavigationWorkspaceIDs = nil
        Task { @MainActor in
            defer { isCreatingTerminalFromSurfaceGrid = false }
            // The compact grid includes aggregated workspaces from secondary
            // Macs. Reuse the shared open path to foreground the owning Mac
            // before terminal.create can use the foreground remote client.
            await store.openWorkspace(workspaceID)
            guard let resolvedWorkspaceID = store.selectedWorkspaceID,
                  store.workspaces.contains(where: { $0.id == resolvedWorkspaceID }),
                  store.createTerminal(in: resolvedWorkspaceID)
            else {
                return
            }
            guard let workspace = store.workspaces.first(where: { $0.id == resolvedWorkspaceID }) else { return }
            browserStore.showNonBrowserSurface(for: workspace.browserSurfaceIdentity)
            compactNavigationPath = [resolvedWorkspaceID]
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

    var canCreateWorkspace: Bool {
        canCreateWorkspaceOnForegroundConnection
    }

    private var canCreateTerminal: Bool {
        canCreateWorkspaceOnForegroundConnection && !isCreatingTerminalFromSurfaceGrid
    }

    private var compactSurfaceGridSelectedWorkspaceID: MobileWorkspacePreview.ID? {
        if let selectedWorkspaceID = store.selectedWorkspaceID,
           store.workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            return selectedWorkspaceID
        }
        return store.workspaces.first?.id
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
        canCreateWorkspaceInContext: Bool,
        safeAreaContext: MobileTerminalSafeAreaContext = .fullWidth,
        backButtonConfiguration: WorkspaceBackButtonConfiguration? = nil
    ) -> some View {
        WorkspaceDetailContainer(
            store: store,
            workspaceID: workspaceID,
            createWorkspace: createWorkspace,
            canCreateWorkspace: canCreateWorkspaceInContext,
            renameWorkspace: renameWorkspaceClosure,
            setWorkspaceUnread: setWorkspaceUnreadClosure,
            closeWorkspace: closeWorkspaceClosure,
            safeAreaContext: safeAreaContext,
            backButtonConfiguration: backButtonConfiguration,
            signOut: signOut
        )
    }
}
