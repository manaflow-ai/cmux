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
                deviceSections: store.deviceSections,
                selectedWorkspaceID: store.selectedWorkspaceID,
                navigationStyle: .push,
                selectWorkspace: { id, macID in selectWorkspace(id, onMac: macID) },
                createWorkspace: createWorkspaceInCompactStack,
                refreshAllDevices: refreshAllDevices,
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
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
        .onAppear {
            autoOpenSelectedWorkspaceForSoakIfNeeded()
        }
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            WorkspaceListView(
                deviceSections: store.deviceSections,
                selectedWorkspaceID: store.selectedWorkspaceID,
                navigationStyle: .sidebar,
                selectWorkspace: { id, macID in selectWorkspace(id, onMac: macID) },
                createWorkspace: store.createWorkspace,
                refreshAllDevices: refreshAllDevices,
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

    private func selectWorkspace(_ id: MobileWorkspacePreview.ID, onMac macDeviceID: String) {
        pendingCompactCreateNavigationWorkspaceIDs = nil
        // Carry the source Mac so a same-id collision across Macs resolves to the
        // tapped section's partition (and retargets the heavy session if needed).
        store.selectWorkspace(id, onMac: macDeviceID)
        if usesCompactStack, compactNavigationPath.last != id {
            compactNavigationPath = [id]
        }
    }

    /// Re-pull every paired Mac's workspace list. Backs pull-to-refresh and a
    /// device-filter tap. Built as an `async` closure literal so it can be passed
    /// across the list's snapshot boundary without exposing the store to rows.
    private var refreshAllDevices: () async -> Void {
        let store = store
        return { await store.refreshAllPairedMacWorkspaceLists() }
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
