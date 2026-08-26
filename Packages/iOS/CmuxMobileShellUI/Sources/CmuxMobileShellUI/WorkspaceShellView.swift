import CMUXMobileCore
import Foundation
import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileToast
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

private struct WorkspaceRootToolbarRenderContext: Equatable {
    let title: String
    let visibleSelection: WorkspaceMacSelection
    let machines: [WorkspaceFilterMachine]
    var statusLine: WorkspaceConnectionStatusLine?

    static let fallback = WorkspaceRootToolbarRenderContext(
        title: L10n.string("mobile.workspaces.macPicker.connectionLabel", defaultValue: "Computer"),
        visibleSelection: .all,
        machines: []
    )
}

private struct WorkspaceRootToolbarRenderContextKey: EnvironmentKey {
    static let defaultValue = WorkspaceRootToolbarRenderContext.fallback
}

extension EnvironmentValues {
    var workspaceRootToolbarContentWidth: CGFloat {
        get { self[WorkspaceRootToolbarContentWidthKey.self] }
        set { self[WorkspaceRootToolbarContentWidthKey.self] = newValue }
    }

    fileprivate var workspaceRootToolbarRenderContext: WorkspaceRootToolbarRenderContext {
        get { self[WorkspaceRootToolbarRenderContextKey.self] }
        set { self[WorkspaceRootToolbarRenderContextKey.self] = newValue }
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
    let selection: WorkspaceMacSelection
    let select: (WorkspaceMacSelection) -> Void
    let machines: [WorkspaceFilterMachine]
    let showAddDevice: (() -> Void)?
    var statusLine: WorkspaceConnectionStatusLine?

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
                value: WorkspaceMacTitlePickerValue(
                    title: title,
                    isLoading: isLoading,
                    selection: selection,
                    machines: machines,
                    canAddDevice: showAddDevice != nil,
                    labelWidth: WorkspaceRootToolbarSizing.pickerWidth(for: contentWidth),
                    statusLine: statusLine
                ),
                actions: WorkspaceMacTitlePickerActions(
                    select: select,
                    addDevice: showAddDevice
                )
            )
            .equatable()
        }
        ToolbarItem(id: "workspace-list-devices", placement: .topBarLeading) {
            Button(action: openDevices) {
                Image(systemName: "desktopcomputer")
            }
            .accessibilityLabel(L10n.string("mobile.connections.title", defaultValue: "Computers"))
            .accessibilityIdentifier("MobileWorkspaceDevicesButton")
        }
    }
}

private struct WorkspaceRootToolbarLiveContent: ToolbarContent {
    @Environment(\.workspaceRootToolbarRenderContext) private var renderContext

    let openSettings: () -> Void
    let openDevices: () -> Void
    let pendingSelection: WorkspaceMacSelection?
    let select: (WorkspaceMacSelection) -> Void
    let showAddDevice: (() -> Void)?

    var body: some ToolbarContent {
        WorkspaceRootToolbarContent(
            openSettings: openSettings,
            openDevices: openDevices,
            title: renderContext.title,
            isLoading: pendingSelection != nil,
            selection: pendingSelection ?? renderContext.visibleSelection,
            select: select,
            machines: renderContext.machines,
            showAddDevice: showAddDevice,
            statusLine: renderContext.statusLine
        )
    }
}

private struct WorkspaceShellRenderPresentation {
    let selectionScope: WorkspaceMacSelectionScope
    let notificationFeedItems: [MobileNotificationFeedItem]
    let notificationUnreadCount: Int
    let notificationFeedStatus: MobileNotificationFeedStatus
    let selectedNotificationFeedMacDeviceIDs: Set<String>?
    let toolbarMachineSnapshots: WorkspaceMachineSnapshots
    let canCreateWorkspaceForSelection: Bool
}
#endif

struct WorkspaceShellView: View {
    @Bindable var store: CMUXMobileShellStore
    let signOut: @MainActor @Sendable () -> Void
    var isInitialConnectionLoading = false
    var initialConnectionTimedOut = false
    var retryInitialConnection: (() -> Void)?
    /// Present the add-device (pairing) flow from the Computers screen. `nil`
    /// hides the add affordance.
    var showAddDevice: (() -> Void)?
    var showPairingScanner: (() -> Void)?
    /// Whether Tailscale still needs its one-time Mac authorization.
    var tailscalePairingRequired = false
    var showSettings: () -> Void = {}
    var showComputers: () -> Void = {}
    var taskComposerPresentation = MobileChildSheetPresentation()
    let compactNavigationPolicy = WorkspaceShellCompactNavigationPolicy()
    @Environment(MobileDisplaySettings.self) private var displaySettings
    @State var compactNavigationPath: [MobileWorkspacePreview.ID] = []
    @State var pendingCompactCreateNavigationWorkspaceIDs: Set<MobileWorkspacePreview.ID>?
    #if os(iOS)
    @State private var selectedPrimaryTab: MobilePrimaryTab = .workspaces
    /// One-time What's New notice: the unseen-page snapshot captured when the
    /// sheet presents, so remote list changes mid-presentation cannot mutate
    /// an open sheet.
    @Environment(MobileWhatsNewCenter.self) private var whatsNewCenter: MobileWhatsNewCenter?
    @State private var whatsNewSheetPages: [MobileWhatsNewPage] = []
    @State private var showsWhatsNewSheet = false
    @State private var notificationNavigationPath: [MobileWorkspacePreview.ID] = []
    @State private var notificationSearchNavigationPath: [MobileWorkspacePreview.ID] = []
    @State private var workspaceSearchNavigationPath: [MobileWorkspacePreview.ID] = []
    @State private var pendingPrimarySearchWorkspaceNavigationID: MobileWorkspacePreview.ID?
    @State private var pendingPrimarySearchNotificationNavigationID: MobileWorkspacePreview.ID?
    // A NavigationStack path write only reaches UIKit while the stack is in the
    // window. Writing a push mid tab-transition (search morph still animating)
    // records the pushed state without pushing, which strands the root list
    // with the tab bar and toolbar hidden. These flags defer pending pushes to
    // the destination stack's own onAppear.
    @State private var workspacesStackIsOnScreen = false
    @State private var notificationsStackIsOnScreen = false
    // Set when a workspace is opened from search results: popping back then
    // finishes the search round on the Workspaces tab with the query cleared,
    // instead of stranding the user on a deactivated search tab whose selected
    // (tinted) search control suggests a search is still in progress.
    @State private var searchSelectionReturnsToWorkspaces = false
    @State private var rootToolbarMachineSnapshots: WorkspaceMachineSnapshots?
    @State private var rootToolbarPendingSelection: WorkspaceMacSelection?
    @State private var rootToolbarSelectionTask: Task<Void, Never>?
    @State private var rootToolbarSelectionGeneration: UInt64 = 0
    #endif
    @State private var primarySearchCoordinator = MobilePrimarySearchCoordinator()
    @State private var workspaceListFilterState = WorkspaceListFilterState()
    @State private var notificationFeedProjection = NotificationFeedProjection()
    @State private var hasPresentedSplitDetail = false
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var macSelection: WorkspaceMacSelection = .all
    /// Legacy fallback while the toast presenter is disabled: the old
    /// dismissible bottom banner for workspace-action failures.
    @State var workspaceActionToast: WorkspaceActionToastContent?
    var workspaceActionToastClock: any Clock<Duration> = ContinuousClock()
    @Environment(ToastCenter.self) var toasts
    @State private var pendingMacSwitchID: String?
    @State private var pendingMacSwitchGeneration: UInt64 = 0
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    var usesCompactStack: Bool {
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
        let presentation = workspaceShellRenderPresentation
        let toolbarRenderContext = rootToolbarRenderContext(for: presentation)
        let visibleSimulatorWorkspaceID = Self.visibleSimulatorStreamWorkspaceID(
            selectedPrimaryTab: selectedPrimaryTab,
            searchScope: primarySearchCoordinator.scope,
            usesCompactStack: usesCompactStack,
            selectedWorkspaceID: store.selectedWorkspaceID,
            compactNavigationPath: compactNavigationPath,
            notificationNavigationPath: notificationNavigationPath,
            workspaceSearchNavigationPath: workspaceSearchNavigationPath,
            notificationSearchNavigationPath: notificationSearchNavigationPath
        )
        GeometryReader { geometry in
            MobilePrimaryTabScaffold(
                selection: $selectedPrimaryTab,
                searchCoordinator: primarySearchCoordinator,
                notificationUnreadCount: presentation.notificationUnreadCount,
                taskComposerAction: usesCompactStack && !compactNavigationPath.isEmpty
                    ? nil
                    : taskComposerAction
            ) {
                workspaceTabContent(
                    canCreateWorkspaceForSelection: presentation.canCreateWorkspaceForSelection
                )
            } notifications: {
                NavigationStack(path: $notificationNavigationPath) {
                    NotificationFeedStoreView(
                        store: store,
                        items: presentation.notificationFeedItems,
                        status: presentation.notificationFeedStatus,
                        projection: notificationFeedProjection,
                        selectedMacDeviceIDs: presentation.selectedNotificationFeedMacDeviceIDs
                    )
                        .toolbar {
                            if notificationNavigationPath.isEmpty {
                                rootToolbarContent
                            }
                        }
                        .navigationDestination(for: MobileWorkspacePreview.ID.self) { workspaceID in
                            workspaceDestination(
                                for: workspaceID,
                                createWorkspace: createWorkspaceInCompactStack,
                                canCreateWorkspaceForSelection: presentation.canCreateWorkspaceForSelection
                            )
                            .toolbarVisibility(.hidden, for: .tabBar)
                    }
                }
                .onAppear {
                    notificationsStackIsOnScreen = true
                    consumePendingPrimarySearchNavigation(for: .notifications)
                }
                .onDisappear {
                    notificationsStackIsOnScreen = false
                }
                .onChange(of: pendingPrimarySearchNotificationNavigationID) { _, _ in
                    consumePendingPrimarySearchNavigation(for: .notifications)
                }
            } workspaceSearch: {
                workspaceSearchTabContent(
                    canCreateWorkspaceForSelection: presentation.canCreateWorkspaceForSelection
                )
            } notificationSearch: {
                notificationSearchTabContent(presentation: presentation)
            }
            .background {
                NotificationFeedSearchProjectionSync(
                    searchCoordinator: primarySearchCoordinator,
                    projection: notificationFeedProjection
                )
            }
            .environment(\.workspaceRootToolbarContentWidth, geometry.size.width)
            .environment(\.workspaceRootToolbarRenderContext, toolbarRenderContext)
            .onChange(of: primarySearchCoordinator.isPresented) { _, isPresented in
                store.recordAppEvent(
                    isPresented ? .searchPresented : .searchDismissed,
                    detail: .searchScope(diagnosticSearchScope)
                )
                if !isPresented {
                    consumePendingPrimarySearchNavigation(for: selectedPrimaryTab)
                }
            }
            .onChange(of: selectedPrimaryTab) { oldValue, newValue in
                store.recordAppEvent(
                    .primaryTabSelected,
                    detail: .primaryTab(diagnosticPrimaryTab(newValue))
                )
                if oldValue == .search, newValue != .search {
                    notificationSearchNavigationPath = []
                    workspaceSearchNavigationPath = []
                    searchSelectionReturnsToWorkspaces = false
                }
            }
            .onChange(of: visibleSimulatorWorkspaceID) { previousWorkspaceID, workspaceID in
                guard let previousWorkspaceID,
                      previousWorkspaceID != workspaceID else { return }
                store.stopActiveMobileSimulatorStream(in: previousWorkspaceID)
            }
            .onChange(of: workspaceSearchNavigationPath) { _, path in
                guard path.isEmpty, searchSelectionReturnsToWorkspaces else { return }
                searchSelectionReturnsToWorkspaces = false
                guard selectedPrimaryTab == .search else { return }
                primarySearchCoordinator.workspaces = ""
                selectedPrimaryTab = .workspaces
            }
            .onChange(of: store.deeplinkWorkspaceNavigationRequest) { _, request in
                guard request != nil else { return }
                consumeDeeplinkNavigationRequestIfNeeded()
            }
            .onAppear {
                store.recordAppEvent(
                    .primaryTabSelected,
                    detail: .primaryTab(diagnosticPrimaryTab(selectedPrimaryTab))
                )
                updateRootToolbarMachineSnapshots(presentation.toolbarMachineSnapshots)
                consumeDeeplinkNavigationRequestIfNeeded()
            }
            .onChange(of: presentation.toolbarMachineSnapshots) { _, snapshots in
                updateRootToolbarMachineSnapshots(snapshots)
            }
            .onChange(of: presentation.notificationFeedItems, initial: true) { _, items in
                notificationFeedProjection.update(items: items)
            }
        }
        #else
        workspaceTabContent(canCreateWorkspaceForSelection: canCreateWorkspaceForMacSelection)
        .onAppear {
            consumeDeeplinkNavigationRequestIfNeeded()
        }
        #endif
    }

    private func workspaceTabContent(canCreateWorkspaceForSelection: Bool) -> some View {
        workspaceActionToastOverlay {
            layoutContent(canCreateWorkspaceForSelection: canCreateWorkspaceForSelection)
        }
    }

    private func workspaceSearchTabContent(canCreateWorkspaceForSelection: Bool) -> some View {
        workspaceActionToastOverlay {
            NavigationStack(path: $workspaceSearchNavigationPath) {
                MobilePrimaryWorkspaceSearchContentHost(
                    searchCoordinator: primarySearchCoordinator
                ) { searchText in
                    workspaceList(
                        navigationStyle: .push,
                        searchText: searchText,
                        canCreateWorkspaceForSelection: canCreateWorkspaceForSelection,
                        showsNavigationToolbar: true,
                        selectWorkspaceAction: selectWorkspaceFromSearch,
                        createWorkspaceAction: createWorkspaceFromSearch,
                        createWorkspaceInGroupAction: createWorkspaceInGroupFromSearchClosure,
                        createWorkspaceGroupAction: createWorkspaceGroupFromSearchClosure
                    )
                }
                .toolbar {
                    if workspaceSearchNavigationPath.isEmpty {
                        rootToolbarContent
                    }
                }
                // Selecting a search result opens the workspace inside the
                // search tab's own stack, exactly like notification search.
                // Transitioning to the Workspaces tab and pushing on its stack
                // from here raced the search-field dismissal and could record
                // the push without performing it, stranding the list with no
                // tab bar (the "stuck after selecting from search" bug).
                .navigationDestination(for: MobileWorkspacePreview.ID.self) { workspaceID in
                    workspaceDestination(
                        for: workspaceID,
                        createWorkspace: createWorkspaceInCompactStack,
                        canCreateWorkspaceForSelection: canCreateWorkspaceForSelection
                    )
                    .toolbarVisibility(.hidden, for: .tabBar)
                }
            }
        }
    }

    @ViewBuilder
    private func workspaceActionToastOverlay<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        // If the presenter is re-enabled, failures surface through the
        // app-wide toast layer; the legacy bottom banner remains the fallback.
        ZStack(alignment: .bottom) {
            content()
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

    private func notificationSearchTabContent(
        presentation: WorkspaceShellRenderPresentation
    ) -> some View {
        NavigationStack(path: $notificationSearchNavigationPath) {
            NotificationFeedStoreView(
                store: store,
                items: presentation.notificationFeedItems,
                status: presentation.notificationFeedStatus,
                projection: notificationFeedProjection,
                selectedMacDeviceIDs: presentation.selectedNotificationFeedMacDeviceIDs
            )
            .toolbar {
                if notificationSearchNavigationPath.isEmpty {
                    rootToolbarContent
                }
            }
            .navigationDestination(for: MobileWorkspacePreview.ID.self) { workspaceID in
                workspaceDestination(
                    for: workspaceID,
                    createWorkspace: createWorkspaceInCompactStack,
                    canCreateWorkspaceForSelection: presentation.canCreateWorkspaceForSelection
                )
                .toolbarVisibility(.hidden, for: .tabBar)
            }
        }
    }

    private func layoutContent(canCreateWorkspaceForSelection: Bool) -> some View {
        Group {
            if usesCompactStack {
                stackLayout(canCreateWorkspaceForSelection: canCreateWorkspaceForSelection)
            } else {
                splitLayout(canCreateWorkspaceForSelection: canCreateWorkspaceForSelection)
            }
        }
        .onChange(of: usesCompactStack) { _, isCompact in
            guard isCompact, hasPresentedSplitDetail, let selectedWorkspaceID = store.selectedWorkspaceID else {
                return
            }
            compactNavigationPath = [selectedWorkspaceID]
        }
        #if os(iOS)
        .taskComposerPresentation(
            isPresented: taskComposerPresentation.isPresented,
            onDismiss: taskComposerPresentation.didDismiss
        ) { launch, switchDraft in
            TaskComposerSheet(
                store: store,
                launchIntent: launch.intent,
                onSwitchDraft: switchDraft,
                submitTaskComposer: submitTaskComposerFromShell
            )
        }
        // One-time What's New notice. Only users who already HAVE Computers
        // see it (fresh installs learn the same things in onboarding). The
        // gate first answers from the cached remote list, then refreshes the
        // list and re-checks. The shell can restore straight into cached
        // workspaces without ever loading the paired-Mac list (it normally
        // loads on the Computers sheet or a reconnect pass), so load it here
        // and re-check, otherwise the has-Computers gate never answers.
        .onAppear {
            presentWhatsNewIfNeeded()
        }
        // `.task` (not an unstructured Task in onAppear) so the refresh and
        // paired-Mac load are owned by the view: cancelled on disappear and
        // never running concurrently across repeated shell appearances. The
        // explicit cancellation checks matter because `refresh()` absorbs a
        // cancelled load into its cache-wins error handling instead of
        // rethrowing, which would otherwise let this task keep working for a
        // view that is already gone.
        .task {
            await whatsNewCenter?.refresh()
            guard !Task.isCancelled else { return }
            await store.loadPairedMacs()
            guard !Task.isCancelled else { return }
            presentWhatsNewIfNeeded()
        }
        .onChange(of: store.pairedMacs.isEmpty) { _, _ in
            presentWhatsNewIfNeeded()
        }
        .sheet(isPresented: $showsWhatsNewSheet) {
            MobileWhatsNewSheet(
                pages: whatsNewSheetPages,
                allowedWebHosts: whatsNewCenter?.allowedWebHosts ?? [],
                dismiss: { showsWhatsNewSheet = false }
            )
            .presentationDetents([.large])
            // Acknowledge on the sheet's ACTUAL appearance, not at gate time:
            // a competing presentation (e.g. a state-restored Settings sheet)
            // can swallow this presentation entirely, and gate-time
            // acknowledgement would burn the marker for pages nobody saw.
            // First appearance still acknowledges everything shown, so a kill
            // mid-presentation cannot re-show the sheet forever.
            .onAppear {
                whatsNewCenter?.acknowledge(whatsNewSheetPages)
            }
        }
        #endif
        .accessibilityIdentifier("MobileWorkspaceShell")
    }

    #if os(iOS)
    /// Presents the one-time What's New sheet when there are unseen pages
    /// and the device already has Computers. Acknowledgement happens in the
    /// sheet content's `onAppear` (first actual presentation, not on
    /// dismiss): early enough that a kill mid-presentation cannot re-show
    /// the sheet forever, late enough that a swallowed presentation (a
    /// state-restored sheet already occupying the presenter) never marks
    /// pages as seen.
    private func presentWhatsNewIfNeeded() {
        guard let whatsNewCenter,
              !store.pairedMacs.isEmpty,
              !showsWhatsNewSheet else { return }
        let pages = whatsNewCenter.unseenPages
        guard !pages.isEmpty else { return }
        whatsNewSheetPages = pages
        showsWhatsNewSheet = true
    }
    #endif

    private func stackLayout(canCreateWorkspaceForSelection: Bool) -> some View {
        NavigationStack(path: $compactNavigationPath) {
            MobilePrimaryWorkspaceSearchHost(
                searchCoordinator: primarySearchCoordinator,
                taskComposerAction: taskComposerAction
            ) { searchText in
                workspaceList(
                    navigationStyle: .push,
                    searchText: searchText,
                    canCreateWorkspaceForSelection: canCreateWorkspaceForSelection
                )
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
                    canCreateWorkspaceForSelection: canCreateWorkspaceForSelection,
                    backButtonConfiguration: WorkspaceBackButtonConfiguration(
                        unreadCount: unreadWorkspaceCount(excluding: workspaceID),
                        badgeContrast: .darkBackground,
                        action: popCompactStack
                    )
                )
                    #if os(iOS)
                    .toolbarVisibility(.hidden, for: .tabBar, .bottomBar)
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
            workspacesStackIsOnScreen = true
            autoOpenSelectedWorkspaceForSoakIfNeeded()
            consumePendingPrimarySearchNavigation(for: .workspaces)
        }
        .onDisappear {
            workspacesStackIsOnScreen = false
        }
        .onChange(of: pendingPrimarySearchWorkspaceNavigationID) { _, _ in
            consumePendingPrimarySearchNavigation(for: .workspaces)
        }
    }

    private func openTaskComposer() {
        taskComposerPresentation.present()
    }

    private var taskComposerAction: (() -> Void)? {
        guard store.supportsTaskComposer else { return nil }
        return openTaskComposer
    }

    private func splitLayout(canCreateWorkspaceForSelection: Bool) -> some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            MobilePrimaryWorkspaceSearchHost(
                searchCoordinator: primarySearchCoordinator,
                taskComposerAction: taskComposerAction
            ) { searchText in
                workspaceList(
                    navigationStyle: .sidebar,
                    searchText: searchText,
                    canCreateWorkspaceForSelection: canCreateWorkspaceForSelection
                )
            }
            .toolbar {
                rootToolbarContent
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            workspaceDestination(
                for: store.selectedWorkspaceID,
                createWorkspace: createWorkspaceIfConnected,
                canCreateWorkspaceForSelection: canCreateWorkspaceForSelection,
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
        searchText: String,
        canCreateWorkspaceForSelection: Bool,
        showsNavigationToolbar: Bool? = nil,
        selectWorkspaceAction: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        createWorkspaceAction: (() -> Void)? = nil,
        createWorkspaceInGroupAction: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil,
        createWorkspaceGroupAction: (() -> Void)? = nil
    ) -> some View {
        let resolvedSelectWorkspace = selectWorkspaceAction ?? selectWorkspace
        let resolvedCreateWorkspace = createWorkspaceAction ?? (
            navigationStyle == .push
                ? createWorkspaceInCompactStack
                : createWorkspaceIfConnected
        )
        let resolvedCreateWorkspaceInGroup = createWorkspaceInGroupAction ?? (
            navigationStyle == .push
                ? createWorkspaceInGroupInCompactStackClosure
                : createWorkspaceInGroupIfConnectedClosure
        )
        let resolvedCreateWorkspaceGroup = createWorkspaceGroupAction ?? (
            navigationStyle == .push
                ? createWorkspaceGroupInCompactStackClosure
                : createWorkspaceGroupIfConnectedClosure
        )
        return WorkspaceListView(
            workspaces: store.workspaces,
            groups: store.workspaceGroups,
            selectedWorkspaceID: store.selectedWorkspaceID,
            host: store.connectedHostName,
            connectionStatus: listConnectionStatus,
            workspaceChangesCapable: store.workspaceChangesCapable,
            workspaceChangeChipsByWorkspaceID: store.workspaceChangeChipsByWorkspaceID,
            macUpdateHint: store.macUpdateHint,
            macUpdateHintMacName: store.connectedHostName,
            dismissMacUpdateHint: { store.dismissMacUpdateHint() },
            navigationStyle: navigationStyle,
            showsNavigationToolbar: showsNavigationToolbar
                ?? (navigationStyle != .push || compactNavigationPath.isEmpty),
            usesExternalSharedToolbar: true,
            wrapWorkspaceTitles: displaySettings.wrapWorkspaceTitles,
            previewLineLimit: displaySettings.workspacePreviewLineCount,
            unreadIndicatorLeftShift: displaySettings.unreadIndicatorLeftShift,
            selectWorkspace: resolvedSelectWorkspace,
            createWorkspace: resolvedCreateWorkspace,
            createWorkspaceInGroup: resolvedCreateWorkspaceInGroup,
            createWorkspaceGroup: resolvedCreateWorkspaceGroup,
            canCreateWorkspace: canCreateWorkspaceForSelection,
            macSelection: $macSelection,
            switchMac: { macDeviceID, instanceTag in
                await switchMacFromWorkspacePicker(
                    macDeviceID: macDeviceID,
                    instanceTag: instanceTag
                )
            },
            cancelMacSwitch: cancelMacSwitchFromWorkspacePicker,
            refresh: refreshWorkspacesClosure,
            signOut: signOut,
            reconnect: tailscalePairingRequired ? showPairingScanner : reconnectClosure,
            tailscalePairingRequired: tailscalePairingRequired,
            showAddDevice: showAddDevice,
            showComputers: showComputers,
            showPairingScanner: showPairingScanner,
            store: store,
            renameWorkspace: renameWorkspaceClosure,
            customizeWorkspace: customizeWorkspaceClosure,
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
            workspaceSortMode: store.workspaceSortMode,
            setWorkspaceSortMode: { store.setWorkspaceSortMode($0) },
            workspaceComputerPriority: store.workspaceComputerPriority,
            setWorkspaceComputerPriority: { store.setWorkspaceComputerPriority($0) },
            filterState: workspaceListFilterState,
            searchText: searchText
        )
    }

    #if os(iOS)
    @ToolbarContentBuilder
    private var rootToolbarContent: some ToolbarContent {
        WorkspaceRootToolbarLiveContent(
            openSettings: showSettings,
            openDevices: showComputers,
            pendingSelection: rootToolbarPendingSelection,
            select: handleRootToolbarSelection,
            showAddDevice: showAddDevice
        )
    }

    /// The Mail-style status line under the computers picker. Derived through
    /// the same chrome policy as the list rows so exactly one surface owns the
    /// connection story: reauth and initial restore render their own chrome,
    /// transient degradation renders only this line.
    private var toolbarConnectionStatusLine: WorkspaceConnectionStatusLine? {
        WorkspaceListConnectionChrome(
            hasStore: true,
            connectionRequiresReauth: store.connectionRequiresReauth,
            connectionRecoveryFailed: store.connectionRecoveryFailed,
            isRecoveringConnection: store.isRecoveringConnection,
            connectionStatus: listConnectionStatus,
            tailscalePairingRequired: tailscalePairingRequired,
            isInitialConnectionLoading: isInitialConnectionLoading,
            initialConnectionTimedOut: initialConnectionTimedOut,
            hasLiveTransportPath: store.workspaceListHasLiveTransportPath
        ).statusLine
    }

    private var workspaceShellRenderPresentation: WorkspaceShellRenderPresentation {
        let scope = macSelectionScope
        let selectedMachineIDs = scope.selectedScopeEntries
        let visibleNotificationFeedItems = store.notificationFeedItems(scopedTo: selectedMachineIDs)
        let notificationUnreadCount = visibleNotificationFeedItems.lazy.filter { !$0.isRead }.count
        var names: [String: String] = [:]
        for workspace in store.workspaces {
            if let id = workspace.macDeviceID,
               let name = workspace.macDisplayName,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                names[id] = name
                names[MobilePairedMac.pairingID(
                    macDeviceID: id,
                    instanceTag: workspace.macInstanceTag
                )] = name
            }
        }
        for item in store.notificationFeedItems {
            if !item.macDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                names[item.macDeviceID] = item.macDisplayName
                names[MobilePairedMac.pairingID(
                    macDeviceID: item.macDeviceID,
                    instanceTag: item.macInstanceTag
                )] = item.macDisplayName
            }
        }
        for device in store.deviceTreeDevices {
            if let name = device.displayName, !name.isEmpty {
                names[device.deviceId] = name
            }
        }
        for mac in store.pairedMacs + store.displayPairedMacs {
            names[mac.macDeviceID] = mac.resolvedName
            names[mac.id] = mac.resolvedName
        }
        if let buildScope = MobileIOSBuildScope.current() {
            names = names.mapValues(buildScope.computerDisplayName)
        }

        let buildLabelsByID = store.pairedMacBuildLabelsByEntryID()
        let toolbarMachineSnapshots = WorkspaceMachineSnapshots(
            workspaces: store.workspaces,
            filterMachineIDFor: { scope.aliasIndex.representativeID(for: $0) },
            macPickerMachineIDs: scope.machineIDs,
            namesByID: names,
            buildLabelsByID: buildLabelsByID,
            fallbackName: L10n.string("mobile.workspaces.macPicker.connectionLabel", defaultValue: "Computer")
        )
        return WorkspaceShellRenderPresentation(
            selectionScope: scope,
            notificationFeedItems: visibleNotificationFeedItems,
            notificationUnreadCount: notificationUnreadCount,
            notificationFeedStatus: store.notificationFeedStatus(scopedTo: selectedMachineIDs),
            selectedNotificationFeedMacDeviceIDs: selectedMachineIDs,
            toolbarMachineSnapshots: toolbarMachineSnapshots,
            canCreateWorkspaceForSelection: scope.canCreateWorkspace(
                base: canCreateWorkspace,
                switchPending: pendingMacSwitchID != nil
            )
        )
    }

    private func rootToolbarRenderContext(
        for presentation: WorkspaceShellRenderPresentation
    ) -> WorkspaceRootToolbarRenderContext {
        let machineSnapshots = rootToolbarMachineSnapshots ?? presentation.toolbarMachineSnapshots
        let visibleSelection = presentation.selectionScope.visibleSelection
        let title: String
        switch visibleSelection {
        case .all, .automatic:
            title = L10n.string("mobile.workspaces.macPicker.allConnections", defaultValue: "All Computers")
        case .machine(let id):
            title = machineSnapshots.macPickerTitle(
                for: id,
                fallback: L10n.string("mobile.workspaces.macPicker.connectionLabel", defaultValue: "Computer")
            )
        }
        return WorkspaceRootToolbarRenderContext(
            title: title,
            visibleSelection: visibleSelection,
            machines: machineSnapshots.macPickerMachines,
            statusLine: toolbarConnectionStatusLine
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
            if case .machine(let id) = selection,
               startsSwitch,
               let target = macSelectionScope.switchTarget(for: id) {
                let switched = await switchMacFromWorkspacePicker(
                    macDeviceID: target.macDeviceID,
                    instanceTag: target.instanceTag
                )
                guard !Task.isCancelled,
                      rootToolbarSelectionGeneration == generation,
                      switched else { return }
            }
        }
        rootToolbarSelectionTask = task
    }

    private func rootToolbarSelectionNeedsMacSwitch(_ selection: WorkspaceMacSelection) -> Bool {
        guard case .machine(let id) = selection else { return false }
        return macSelectionScope.shouldSwitch(to: id)
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
            switch primarySearchCoordinator.notificationFeedNavigationRoute(
                selectedTab: selectedPrimaryTab
            ) {
            case .mountedNotificationSearch:
                if notificationSearchNavigationPath.last != workspaceID {
                    notificationSearchNavigationPath = [workspaceID]
                }
            case .notificationTabAfterSearchDismissal:
                pendingPrimarySearchNotificationNavigationID = workspaceID
                transitionPrimaryTab(to: .notifications)
            case .mountedNotificationTab:
                transitionPrimaryTab(to: .notifications)
                if notificationNavigationPath.last != workspaceID {
                    notificationNavigationPath = [workspaceID]
                }
            }
            return
        }
        if selectedPrimaryTab == .search || primarySearchCoordinator.isPresented {
            pendingPrimarySearchWorkspaceNavigationID = workspaceID
            transitionPrimaryTab(to: .workspaces)
        } else {
            transitionPrimaryTab(to: .workspaces) {
                guard usesCompactStack, compactNavigationPath.last != workspaceID else { return }
                compactNavigationPath = [workspaceID]
            }
        }
        #endif
        guard usesCompactStack else { return }
    }

    private func consumePendingPrimarySearchNavigation(for tab: MobilePrimaryTab) {
        guard !primarySearchCoordinator.isPresented else { return }
        switch tab {
        case .workspaces:
            // Compact pushes must wait for the workspaces stack to be in the
            // window (its onAppear re-runs this); the split layout only writes
            // the store selection, which is safe at any time.
            guard !usesCompactStack || workspacesStackIsOnScreen else { return }
            guard let workspaceID = pendingPrimarySearchWorkspaceNavigationID else { return }
            pendingPrimarySearchWorkspaceNavigationID = nil
            selectWorkspaceImmediately(workspaceID)
        case .notifications:
            guard notificationsStackIsOnScreen else { return }
            guard let workspaceID = pendingPrimarySearchNotificationNavigationID else { return }
            pendingPrimarySearchNotificationNavigationID = nil
            if notificationNavigationPath.last != workspaceID {
                notificationNavigationPath = [workspaceID]
            }
        case .search:
            break
        }
    }

    @discardableResult
    private func transitionPrimaryTab(
        to tab: MobilePrimaryTab,
        beforeSelection: () -> Void = {}
    ) -> Bool {
        let previousTab = selectedPrimaryTab
        if (selectedPrimaryTab == .search || primarySearchCoordinator.isPresented),
           tab.searchScope != nil {
            primarySearchCoordinator.deactivateCurrentSearch()
        }
        beforeSelection()
        selectedPrimaryTab = tab
        return previousTab != tab
    }

    private func selectWorkspace(_ id: MobileWorkspacePreview.ID) {
        #if os(iOS)
        if selectedPrimaryTab == .search || primarySearchCoordinator.isPresented {
            pendingPrimarySearchWorkspaceNavigationID = id
            transitionPrimaryTab(to: .workspaces)
            return
        }
        #endif
        selectWorkspaceImmediately(id)
    }

    private func selectWorkspaceImmediately(_ id: MobileWorkspacePreview.ID) {
        pendingCompactCreateNavigationWorkspaceIDs = nil
        store.selectedWorkspaceID = id
        if usesCompactStack, compactNavigationPath.last != id {
            compactNavigationPath = [id]
        }
    }

    /// Opens a workspace tapped in the search results by pushing it onto the
    /// search tab's own stack — no tab transition, so the push cannot land on
    /// an off-window stack. Choosing a result also ends the search session
    /// (committing the query, like every other search exit): left presented,
    /// the field re-presents after popping anchored to the navigation bar at
    /// the top instead of the search tab's bottom control. Popping back lands
    /// on the still-filtered results with the bottom search control collapsed.
    private func selectWorkspaceFromSearch(_ id: MobileWorkspacePreview.ID) {
        store.recordAppEvent(
            .searchResultSelected,
            correlationID: id.rawValue,
            detail: .searchScope(.workspaces)
        )
        pendingCompactCreateNavigationWorkspaceIDs = nil
        primarySearchCoordinator.deactivateCurrentSearch()
        searchSelectionReturnsToWorkspaces = true
        store.selectedWorkspaceID = id
        if workspaceSearchNavigationPath.last != id {
            workspaceSearchNavigationPath = [id]
        }
    }

    private func diagnosticPrimaryTab(_ tab: MobilePrimaryTab) -> DiagnosticPrimaryTab {
        switch tab {
        case .workspaces: .workspaces
        case .notifications: .notifications
        case .search: .search
        }
    }

    private var diagnosticSearchScope: DiagnosticSearchScope {
        switch primarySearchCoordinator.scope {
        case .workspaces: .workspaces
        case .notifications: .notifications
        }
    }

    private func createWorkspaceFromSearch() {
        transitionPrimaryTab(to: .workspaces) {
            if usesCompactStack {
                createWorkspaceInCompactStack()
            } else {
                createWorkspaceIfConnected()
            }
        }
    }

    private var createWorkspaceInGroupFromSearchClosure: ((MobileWorkspaceGroupPreview.ID) -> Void)? {
        guard store.supportsWorkspaceCreateInGroup else { return nil }
        return { groupID in
            transitionPrimaryTab(to: .workspaces) {
                if usesCompactStack {
                    createWorkspaceInCompactStack(inGroup: groupID)
                } else {
                    createWorkspaceIfConnected(inGroup: groupID)
                }
            }
        }
    }

    private var createWorkspaceGroupFromSearchClosure: (() -> Void)? {
        guard store.supportsWorkspaceGroupCreate else { return nil }
        return {
            transitionPrimaryTab(to: .workspaces) {
                createWorkspaceGroupIfConnected()
            }
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
    private func switchMacFromWorkspacePicker(
        macDeviceID: String,
        instanceTag: String?
    ) async -> Bool {
        pendingMacSwitchGeneration &+= 1
        let generation = pendingMacSwitchGeneration
        pendingMacSwitchID = macDeviceID
        defer {
            if pendingMacSwitchGeneration == generation {
                pendingMacSwitchID = nil
            }
        }
        return await store.switchToMac(macDeviceID: macDeviceID, instanceTag: instanceTag)
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
            foregroundInstanceTag: store.connectedMacInstanceTag,
            aliasesFor: {
                store.pairedMacAliasIDs(for: $0, instanceTag: $1)
            }
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
        canCreateWorkspaceForSelection: Bool,
        safeAreaContext: MobileTerminalSafeAreaContext = .fullWidth,
        backButtonConfiguration: WorkspaceBackButtonConfiguration? = nil
    ) -> some View {
        WorkspaceDetailContainer(
            store: store,
            workspaceID: workspaceID,
            createWorkspace: createWorkspace,
            canCreateWorkspace: canCreateWorkspaceForSelection,
            renameWorkspace: renameWorkspaceClosure,
            customizeWorkspace: customizeWorkspaceClosure,
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

        // The terminal and browser both cover the pushed workspace detail with
        // scroll views. Letting their pans recognize alongside the pop gesture
        // makes a diagonal back swipe scroll the surface while navigation moves.
        // The dynamic failure rule below restores the system ownership order:
        // off-edge touches fail the edge recognizer and then scroll normally,
        // while an edge touch lets navigation win without dual recognition.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard gestureRecognizer === navigationController?.interactivePopGestureRecognizer,
                  otherGestureRecognizer is UIPanGestureRecognizer,
                  let navigationView = navigationController?.view,
                  let otherView = otherGestureRecognizer.view else {
                return false
            }
            return otherView.isDescendant(of: navigationView)
        }
    }
}
#endif
