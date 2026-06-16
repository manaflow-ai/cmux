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
    @Environment(MobileDisplaySettings.self) private var displaySettings
    @State private var compactNavigationPath: [MobileWorkspacePreview.ID] = []
    @State private var pendingCompactCreateNavigationWorkspaceIDs: Set<MobileWorkspacePreview.ID>?
    @State private var hasPresentedSplitDetail = false
    @State private var splitColumnVisibility: NavigationSplitViewVisibility = .automatic
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

    var body: some View {
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
        .overlay(alignment: .top) {
            MobileConnectionRecoveryBanner(store: store, signOut: signOut)
        }
    }

    private var stackLayout: some View {
        NavigationStack(path: $compactNavigationPath) {
            WorkspaceListView(
                workspaces: store.workspaces,
                groups: store.workspaceGroups,
                selectedWorkspaceID: store.selectedWorkspaceID,
                host: store.connectedHostName,
                connectionStatus: store.macConnectionStatus,
                navigationStyle: .push,
                wrapWorkspaceTitles: displaySettings.wrapWorkspaceTitles,
                previewLineLimit: displaySettings.workspacePreviewLineCount,
                selectWorkspace: selectWorkspace,
                createWorkspace: createWorkspaceInCompactStack,
                refresh: refreshWorkspacesClosure,
                rescanQR: { store.disconnectAndForgetActiveMac() },
                signOut: signOut,
                store: store,
                renameWorkspace: renameWorkspaceClosure,
                setPinned: setWorkspacePinnedClosure,
                setUnread: setWorkspaceUnreadClosure,
                closeWorkspace: closeWorkspaceClosure,
                toggleGroupCollapsed: toggleGroupCollapsedClosure
            )
            .navigationDestination(for: MobileWorkspacePreview.ID.self) { workspaceID in
                workspaceDestination(for: workspaceID, createWorkspace: createWorkspaceInCompactStack)
            }
        }
        .onChange(of: store.selectedWorkspaceID) { _, selectedWorkspaceID in
            if let createdPath = WorkspaceShellCompactNavigationPolicy.pathForCreatedWorkspaceSelection(
                currentPath: compactNavigationPath,
                selectedWorkspaceID: selectedWorkspaceID,
                existingWorkspaceIDs: pendingCompactCreateNavigationWorkspaceIDs
            ) {
                pendingCompactCreateNavigationWorkspaceIDs = nil
                compactNavigationPath = createdPath
                autoOpenSelectedWorkspaceForSoakIfNeeded()
                return
            }
            compactNavigationPath = WorkspaceShellCompactNavigationPolicy.pathForSelectionChange(
                currentPath: compactNavigationPath,
                selectedWorkspaceID: selectedWorkspaceID
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
            compactNavigationPath.removeAll { !workspaceIDs.contains($0) }
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
                connectionStatus: store.macConnectionStatus,
                navigationStyle: .sidebar,
                wrapWorkspaceTitles: displaySettings.wrapWorkspaceTitles,
                previewLineLimit: displaySettings.workspacePreviewLineCount,
                selectWorkspace: selectWorkspace,
                createWorkspace: store.createWorkspace,
                refresh: refreshWorkspacesClosure,
                rescanQR: { store.disconnectAndForgetActiveMac() },
                signOut: signOut,
                store: store,
                renameWorkspace: renameWorkspaceClosure,
                setPinned: setWorkspacePinnedClosure,
                setUnread: setWorkspaceUnreadClosure,
                closeWorkspace: closeWorkspaceClosure,
                toggleGroupCollapsed: toggleGroupCollapsedClosure
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            workspaceDestination(
                for: store.selectedWorkspaceID,
                createWorkspace: store.createWorkspace,
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

    /// Rename/pin closures, present only when the connected Mac advertises the
    /// `workspace.actions.v1` capability so the row affordances stay hidden on
    /// older Macs that lack the handler. Built as explicit closure literals (not
    /// a method-reference ternary, which the compiler fails to type-check inside
    /// the large `WorkspaceListView` initializer).
    private var renameWorkspaceClosure: ((MobileWorkspacePreview.ID, String) -> Void)? {
        guard store.supportsWorkspaceActions else { return nil }
        let store = store
        return { id, title in Task { await store.renameWorkspace(id: id, title: title) } }
    }

    private var setWorkspacePinnedClosure: ((MobileWorkspacePreview.ID, Bool) -> Void)? {
        guard store.supportsWorkspaceActions else { return nil }
        let store = store
        return { id, pinned in Task { await store.setWorkspacePinned(id: id, pinned) } }
    }

    private var setWorkspaceUnreadClosure: ((MobileWorkspacePreview.ID, Bool) -> Void)? {
        guard store.supportsWorkspaceReadStateActions else { return nil }
        let store = store
        return { id, unread in Task { await store.setWorkspaceUnread(id: id, unread) } }
    }

    private var closeWorkspaceClosure: ((MobileWorkspacePreview.ID) -> Void)? {
        guard store.supportsWorkspaceCloseActions else { return nil }
        let store = store
        return { id in Task { await store.closeWorkspace(id: id) } }
    }

    /// Pull-to-refresh closure for the workspace list. Awaits the store's real
    /// `mobile.workspace.list` re-sync so the system refresh spinner reflects the
    /// actual round-trip. Captures `store` as a local so the closure (not a store
    /// reference) is what crosses into the `List`-hosting view.
    private var refreshWorkspacesClosure: @Sendable () async -> Void {
        let store = store
        return { await store.refreshWorkspaces() }
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
        let existingWorkspaceIDs = Set(store.workspaces.map(\.id))
        pendingCompactCreateNavigationWorkspaceIDs = existingWorkspaceIDs
        store.createWorkspace()
        if let createdPath = WorkspaceShellCompactNavigationPolicy.pathForCreatedWorkspaceSelection(
            currentPath: compactNavigationPath,
            selectedWorkspaceID: store.selectedWorkspaceID,
            existingWorkspaceIDs: existingWorkspaceIDs
        ) {
            pendingCompactCreateNavigationWorkspaceIDs = nil
            compactNavigationPath = createdPath
        }
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

    @ViewBuilder
    private func workspaceDestination(
        for workspaceID: MobileWorkspacePreview.ID?,
        createWorkspace: @escaping () -> Void,
        safeAreaContext: MobileTerminalSafeAreaContext = .fullWidth
    ) -> some View {
        WorkspaceDetailContainer(
            store: store,
            workspaceID: workspaceID,
            createWorkspace: createWorkspace,
            safeAreaContext: safeAreaContext
        )
    }
}
