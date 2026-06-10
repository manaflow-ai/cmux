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
    /// Per-workspace unread counts (workspace id raw value → count). Passed in by
    /// the tab container, which is the snapshot-boundary owner for the
    /// notifications store, so this list never reads an `@Observable` store.
    var unreadCountsByWorkspace: [String: Int] = [:]
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
        .accessibilityIdentifier("MobileWorkspaceShell")
        .overlay(alignment: .top) {
            MobileConnectionRecoveryBanner(store: store, signOut: signOut)
        }
    }

    private var stackLayout: some View {
        NavigationStack(path: $compactNavigationPath) {
            WorkspaceListView(
                workspaces: store.workspaces,
                selectedWorkspaceID: store.selectedWorkspaceID,
                host: store.connectedHostName,
                connectionStatus: store.macConnectionStatus,
                navigationStyle: .push,
                wrapWorkspaceTitles: displaySettings.wrapWorkspaceTitles,
                unreadCountsByWorkspace: unreadCountsByWorkspace,
                selectWorkspace: selectWorkspace,
                createWorkspace: createWorkspaceInCompactStack,
                rescanQR: { store.disconnectAndForgetActiveMac() },
                signOut: signOut,
                store: store,
                renameWorkspace: renameWorkspaceClosure,
                setPinned: setWorkspacePinnedClosure
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
            guard let selectedWorkspaceID = path.last,
                  store.selectedWorkspaceID != selectedWorkspaceID else {
                return
            }
            store.selectedWorkspaceID = selectedWorkspaceID
        }
        .onChange(of: store.workspaces.map(\.id)) { _, workspaceIDs in
            compactNavigationPath.removeAll { !workspaceIDs.contains($0) }
            // Replay a pending open whose target only just arrived: an APNs tap
            // during cold attach sets the request while the list is still empty,
            // so the token `onChange` below bails. Without this the deep-link is
            // stranded at the root even after the workspace appears.
            pushPendingWorkspaceOpenIfPossible()
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
        // Explicit open requests (notification tap / deep-link) must push the
        // workspace detail even from the root list, unlike passive selection
        // changes which the navigation policy intentionally ignores at root.
        // Observe the monotonic token so a repeat open of the already-selected
        // workspace still fires.
        .onChange(of: store.pendingWorkspaceOpenRequest?.token) { _, _ in
            pushPendingWorkspaceOpenIfPossible()
        }
        .onAppear {
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            WorkspaceListView(
                workspaces: store.workspaces,
                selectedWorkspaceID: store.selectedWorkspaceID,
                host: store.connectedHostName,
                connectionStatus: store.macConnectionStatus,
                navigationStyle: .sidebar,
                wrapWorkspaceTitles: displaySettings.wrapWorkspaceTitles,
                unreadCountsByWorkspace: unreadCountsByWorkspace,
                selectWorkspace: selectWorkspace,
                createWorkspace: store.createWorkspace,
                rescanQR: { store.disconnectAndForgetActiveMac() },
                signOut: signOut,
                store: store,
                renameWorkspace: renameWorkspaceClosure,
                setPinned: setWorkspacePinnedClosure
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

    private func selectWorkspace(_ id: MobileWorkspacePreview.ID) {
        pendingCompactCreateNavigationWorkspaceIDs = nil
        // Opening a workspace from the list is a read of its activity: clear its
        // unread notification badge optimistically and propagate the read-state
        // to the Mac. Same shared mark-read path the Notifications feed uses, so
        // both entrypoints stay consistent.
        store.markNotificationsRead(forWorkspace: id.rawValue)
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

    /// Push the workspace detail for the latest explicit open request, but only
    /// once its target is present in the list. Safe to call repeatedly: it is a
    /// no-op when there is no pending request, the target is not loaded yet, or
    /// the detail is already on top, so both the request-token `onChange` and the
    /// workspaces-arrived replay path can share it.
    private func pushPendingWorkspaceOpenIfPossible() {
        guard let request = store.pendingWorkspaceOpenRequest,
              store.workspaces.contains(where: { $0.id == request.id }),
              compactNavigationPath.last != request.id else {
            return
        }
        compactNavigationPath = [request.id]
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
