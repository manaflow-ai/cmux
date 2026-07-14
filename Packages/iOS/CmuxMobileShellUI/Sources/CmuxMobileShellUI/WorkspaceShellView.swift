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
    @Environment(MobileDisplaySettings.self) private var displaySettings
    @State var compactNavigationPath: [WorkspaceShellRoute] = []
    @State var splitDetailPath: [WorkspaceShellRoute] = []
    @State var pendingCompactCreateNavigationWorkspaceIDs: Set<MobileWorkspacePreview.ID>?
    @State private var hasPresentedSplitDetail = false
    @State var splitColumnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var macSelection: WorkspaceMacSelection = .all
    @State var workspaceActionToast: WorkspaceActionToastContent?
    @State private var pendingMacSwitchID: String?
    @State private var pendingMacSwitchGeneration: UInt64 = 0
    var workspaceActionToastClock: any Clock<Duration> = ContinuousClock()
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
            let hub = WorkspaceShellRoute.hub(workspaceID: selectedWorkspaceID)
            if let splitRoute = splitDetailPath.last,
               case let .pane(_, paneID, surfaceID) = splitRoute {
                compactNavigationPath = [
                    hub,
                    .pane(workspaceID: selectedWorkspaceID, paneID: paneID, surfaceID: surfaceID),
                ]
            } else {
                compactNavigationPath = [hub]
            }
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
                macUpdateHint: store.macUpdateHint,
                macUpdateHintMacName: store.connectedHostName,
                dismissMacUpdateHint: { store.dismissMacUpdateHint() },
                navigationStyle: .push,
                showsNavigationToolbar: compactNavigationPath.isEmpty,
                wrapWorkspaceTitles: displaySettings.wrapWorkspaceTitles,
                previewLineLimit: displaySettings.workspacePreviewLineCount,
                unreadIndicatorLeftShift: displaySettings.unreadIndicatorLeftShift,
                profilePictureLeftShift: displaySettings.profilePictureLeftShift,
                profilePictureSize: displaySettings.profilePictureSize,
                selectWorkspace: selectWorkspace,
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
            .navigationDestination(for: WorkspaceShellRoute.self) { route in
                compactDestination(for: route)
            }
        }
        .onChange(of: store.selectedWorkspaceID) { _, selectedWorkspaceID in
            if let existingWorkspaceIDs = pendingCompactCreateNavigationWorkspaceIDs,
               let selectedWorkspaceID,
               !existingWorkspaceIDs.contains(selectedWorkspaceID) {
                pendingCompactCreateNavigationWorkspaceIDs = nil
                compactNavigationPath = [.hub(workspaceID: selectedWorkspaceID)]
                autoOpenSelectedWorkspaceForSoakIfNeeded()
                return
            }
            guard !compactNavigationPath.isEmpty else {
                autoOpenSelectedWorkspaceForSoakIfNeeded()
                return
            }
            guard let selectedWorkspaceID else {
                compactNavigationPath = []
                return
            }
            if compactNavigationPath.last?.workspaceID != selectedWorkspaceID {
                compactNavigationPath = [.hub(workspaceID: selectedWorkspaceID)]
            }
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
        .onChange(of: compactNavigationPath) { _, path in
            guard let selectedWorkspaceID = path.last?.workspaceID else {
                return
            }
            pendingCompactCreateNavigationWorkspaceIDs = nil
            guard store.selectedWorkspaceID != selectedWorkspaceID else {
                return
            }
            store.selectedWorkspaceID = selectedWorkspaceID
        }
        .onChange(of: store.workspaces.map(\.id)) { _, workspaceIDs in
            reconcileCompactPath(with: Set(workspaceIDs))
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
                macUpdateHint: store.macUpdateHint,
                macUpdateHintMacName: store.connectedHostName,
                dismissMacUpdateHint: { store.dismissMacUpdateHint() },
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
            NavigationStack(path: $splitDetailPath) {
                workspaceHubDestination(
                    for: store.selectedWorkspaceID,
                    backButtonConfiguration: nil
                )
                .navigationDestination(for: WorkspaceShellRoute.self) { route in
                    splitDestination(for: route)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            hasPresentedSplitDetail = true
        }
        .onChange(of: store.selectedWorkspaceID) { _, selectedWorkspaceID in
            if splitDetailPath.last?.workspaceID != selectedWorkspaceID {
                splitDetailPath = []
            }
        }
    }

    /// Apply (and clear) a pending deep-link navigation intent. On the compact
    /// stack this pushes hub then pane. On split layouts the hub is the detail
    /// root, so a terminal target pushes only the pane level.
    private func consumeDeeplinkNavigationRequestIfNeeded() {
        guard store.deeplinkWorkspaceNavigationRequest != nil else { return }
        guard let request = store.consumeDeeplinkWorkspaceNavigationRequest() else { return }
        let hub = WorkspaceShellRoute.hub(workspaceID: request.workspaceID)
        if usesCompactStack {
            compactNavigationPath = [hub]
            if let terminalID = request.terminalID {
                compactNavigationPath.append(.pane(
                    workspaceID: request.workspaceID,
                    paneID: "deeplink:\(terminalID.rawValue)",
                    surfaceID: terminalID.rawValue
                ))
            }
        } else if let terminalID = request.terminalID {
            splitDetailPath = [.pane(
                workspaceID: request.workspaceID,
                paneID: "deeplink:\(terminalID.rawValue)",
                surfaceID: terminalID.rawValue
            )]
        }
    }

    private func selectWorkspace(_ id: MobileWorkspacePreview.ID) {
        pendingCompactCreateNavigationWorkspaceIDs = nil
        store.selectedWorkspaceID = id
        if usesCompactStack, compactNavigationPath.last?.workspaceID != id {
            compactNavigationPath = [.hub(workspaceID: id)]
        } else if !usesCompactStack {
            splitDetailPath = []
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
        compactNavigationPath = [.hub(workspaceID: selectedWorkspaceID)]
        #endif
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
