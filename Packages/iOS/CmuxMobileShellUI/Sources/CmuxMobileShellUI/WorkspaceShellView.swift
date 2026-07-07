import Foundation
import CmuxMobileShell
import CmuxMobileShellModel
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
    private let compactNavigationPolicy = WorkspaceShellCompactNavigationPolicy()
    @Environment(MobileDisplaySettings.self) private var displaySettings
    @State private var compactNavigationPath: [MobileWorkspacePreview.ID] = []
    @State private var pendingCompactCreateNavigationWorkspaceIDs: Set<MobileWorkspacePreview.ID>?
    @State private var hasPresentedSplitDetail = false
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var macSelection: WorkspaceMacSelection = .all
    @State private var pendingMacSwitchID: String?
    @State private var pendingMacSwitchGeneration: UInt64 = 0
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
        layoutContent
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
            WorkspaceListView(
                workspaces: store.workspaces,
                groups: store.workspaceGroups,
                selectedWorkspaceID: store.selectedWorkspaceID,
                host: store.connectedHostName,
                connectionStatus: listConnectionStatus,
                navigationStyle: .push,
                showsNavigationToolbar: compactNavigationPath.isEmpty,
                wrapWorkspaceTitles: displaySettings.wrapWorkspaceTitles,
                previewLineLimit: displaySettings.workspacePreviewLineCount,
                unreadIndicatorLeftShift: displaySettings.unreadIndicatorLeftShift,
                profilePictureLeftShift: displaySettings.profilePictureLeftShift,
                profilePictureSize: displaySettings.profilePictureSize,
                selectWorkspace: selectWorkspace,
                createWorkspace: createWorkspaceInCompactStack,
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
                toggleGroupCollapsed: toggleGroupCollapsedClosure,
                isInitialConnectionLoading: isInitialConnectionLoading,
                initialConnectionTimedOut: initialConnectionTimedOut,
                retryInitialConnection: retryInitialConnection
            )
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

    /// Workspace action closures, always present for the real store. Row and
    /// detail affordances gate themselves on each workspace's owning-Mac
    /// capability snapshot, so a secondary Mac is not hidden behind the
    /// foreground Mac's advertised capabilities. Built as explicit closure
    /// literals (not method-reference ternaries, which the compiler fails to
    /// type-check inside the large `WorkspaceListView` initializer).
    private var renameWorkspaceClosure: ((MobileWorkspacePreview.ID, String) -> Void)? {
        let store = store
        return { id, title in Task { await store.renameWorkspace(id: id, title: title) } }
    }

    private var setWorkspacePinnedClosure: ((MobileWorkspacePreview.ID, Bool) -> Void)? {
        let store = store
        return { id, pinned in Task { await store.setWorkspacePinned(id: id, pinned) } }
    }

    private var setWorkspaceUnreadClosure: ((MobileWorkspacePreview.ID, Bool) -> Void)? {
        let store = store
        return { id, unread in Task { await store.setWorkspaceUnread(id: id, unread) } }
    }

    private var closeWorkspaceClosure: ((MobileWorkspacePreview.ID) -> Void)? {
        let store = store
        return { id in Task { await store.closeWorkspace(id: id) } }
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

    private var canCreateWorkspaceForMacSelection: Bool {
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

    /// Group collapse/expand closure. Present when the Mac advertises
    /// `workspace.groups.v1` or has actually emitted group sections: a Mac that
    /// emits groups in the workspace list also handles collapse/expand (both
    /// shipped together), and the capability flag arrives via a separate
    /// `mobile.host.status` call that can lag or fail without making the
    /// already-received groups read-only. Older Macs emit no groups, so this
    /// stays `nil` and the list renders flat.
    private var toggleGroupCollapsedClosure: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)? {
        guard store.supportsWorkspaceGroups || !store.workspaceGroups.isEmpty else { return nil }
        let store = store
        return { id, collapsed in Task { await store.setWorkspaceGroupCollapsed(id: id, collapsed) } }
    }

    private func createWorkspaceInCompactStack() {
        guard canCreateWorkspaceForMacSelection else { return }
        let existingWorkspaceIDs = Set(store.workspaces.map(\.id))
        pendingCompactCreateNavigationWorkspaceIDs = existingWorkspaceIDs
        store.createWorkspace()
        if let createdPath = compactNavigationPolicy.pathForCreatedWorkspaceSelection(
            currentPath: compactNavigationPath,
            selectedWorkspaceID: store.selectedWorkspaceID,
            existingWorkspaceIDs: existingWorkspaceIDs
        ) {
            pendingCompactCreateNavigationWorkspaceIDs = nil
            compactNavigationPath = createdPath
        }
    }

    private func createWorkspaceIfConnected() {
        guard canCreateWorkspaceForMacSelection else { return }
        store.createWorkspace()
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
