import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxHive
import CmuxSettings
import CmuxSettingsUI
import CmuxSidebar
import CmuxSidebarProviderKit
import CmuxUpdater
import CmuxWorkspaces
import SwiftUI

/// One paired remote computer as a value snapshot for the sidebar scope
/// picker (snapshot-boundary rule: no store references in row content).
struct HiveScopeComputer: Equatable, Identifiable {
    let id: String
    let name: String
}

/// Which computers' workspaces the sidebar shows — the macOS counterpart of
/// the iOS workspace-title Mac picker's scopes.
enum HiveSidebarScope: Equatable {
    /// Local workspaces only (the default).
    case thisMac
    /// Local workspaces plus every attached computer's mirrors.
    case allComputers
    /// One computer's mirror workspaces only.
    case device(String)
}

/// App-wide sidebar computer scope. Global (not per-window) in v1; scope
/// changes are rare and user-driven.
@MainActor
final class HiveSidebarScopeModel: ObservableObject {
    static let shared = HiveSidebarScopeModel()
    @Published var scope: HiveSidebarScope = .thisMac
    private init() {}

    /// Whether `workspace` is visible under the current scope, given the
    /// device that owns it (`nil` for local workspaces).
    nonisolated static func isVisible(deviceID: String?, scope: HiveSidebarScope) -> Bool {
        switch scope {
        case .thisMac: return deviceID == nil
        case .allComputers: return true
        case .device(let id): return deviceID == id
        }
    }
}

/// Bottom-of-sidebar computer scope picker, shown only in
/// `computers.presentation = sidebar` mode when paired computers exist:
/// switches the main window between This Mac and a remote computer's live
/// workspaces — the macOS counterpart of the iOS workspace-title Mac picker.
struct HiveSidebarScopePicker: View {
    @Binding var selection: SidebarSelection
    @EnvironmentObject var tabManager: TabManager
    @LiveSetting(\.computers.presentation) private var presentation
    @State private var computers: [HiveScopeComputer] = []

    @ObservedObject private var scopeModel = HiveSidebarScopeModel.shared

    var body: some View {
        if presentation == .sidebar, !computers.isEmpty {
            Menu {
                scopeButton(scope: .thisMac, title: thisMacTitle)
                scopeButton(scope: .allComputers, title: allComputersTitle)
                Divider()
                ForEach(computers) { computer in
                    scopeButton(scope: .device(computer.id), title: computer.name)
                }
            } label: {
                Label(currentTitle, systemImage: "desktopcomputer")
                    .cmuxFont(.caption)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("SidebarComputerScopePicker")
            .task { await observeComputers() }
        } else {
            // Keep the observation alive so the picker appears the moment a
            // computer is paired while the sidebar is already visible.
            Color.clear
                .frame(width: 0, height: 0)
                .task { await observeComputers() }
        }
    }

    @ViewBuilder
    private func scopeButton(scope: HiveSidebarScope, title: String) -> some View {
        Button {
            selection = .tabs
            scopeModel.scope = scope
            let manager = tabManager
            // Scoping to a computer (or all) attaches its native mirrors.
            let deviceIDs: [String]
            switch scope {
            case .thisMac: deviceIDs = []
            case .allComputers: deviceIDs = computers.map(\.id)
            case .device(let id): deviceIDs = [id]
            }
            guard !deviceIDs.isEmpty else { return }
            Task { @MainActor in
                for deviceID in deviceIDs {
                    _ = await HiveComputerMirrorController.shared.attach(
                        deviceID: deviceID,
                        into: manager
                    )
                }
            }
        } label: {
            if scopeModel.scope == scope {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var thisMacTitle: String {
        String(localized: "hive.scopePicker.thisMac", defaultValue: "This Mac")
    }

    private var allComputersTitle: String {
        String(localized: "hive.scopePicker.allComputers", defaultValue: "All Computers")
    }

    private var currentTitle: String {
        switch scopeModel.scope {
        case .thisMac: return thisMacTitle
        case .allComputers: return allComputersTitle
        case .device(let id): return computers.first(where: { $0.id == id })?.name ?? thisMacTitle
        }
    }

    private func observeComputers() async {
        guard let directory = HiveComputersService.shared.directory else { return }
        for await merged in directory.updates() {
            let snapshot = merged
                .filter { $0.isPaired && !$0.isThisComputer }
                .map { HiveScopeComputer(id: $0.deviceID, name: $0.displayName) }
            if snapshot != computers { computers = snapshot }
        }
    }
}

/// Footer debug controls and empty-area drop targets for the vertical tabs sidebar, extracted from `ContentView.swift`, which sits at its file-length budget.
struct SidebarFooterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SidebarFooterIconButtonStyleBody(configuration: configuration)
    }
}

private struct SidebarFooterIconButtonStyleBody: View {
    let configuration: SidebarFooterIconButtonStyle.Configuration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var backgroundOpacity: Double {
        guard isEnabled else { return 0.0 }
        if configuration.isPressed { return 0.16 }
        if isHovered { return 0.08 }
        return 0.0
    }

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

#if DEBUG
struct SidebarDevFooter: View {
    var updateViewModel: UpdateStateModel
    @ObservedObject var fileExplorerState: FileExplorerState
    let modifierKeyMonitor: WindowScopedShortcutHintModifierMonitor
    let onSendFeedback: () -> Void
    @AppStorage(DevBuildBannerDebugSettings.sidebarBannerVisibleKey)
    private var showSidebarDevBuildBanner = DevBuildBannerDebugSettings.defaultShowSidebarBanner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SidebarFooterButtons(updateViewModel: updateViewModel, fileExplorerState: fileExplorerState, modifierKeyMonitor: modifierKeyMonitor, onSendFeedback: onSendFeedback)
            if showSidebarDevBuildBanner {
                Text(String(localized: "debug.devBuildBanner.title", defaultValue: "THIS IS A DEV BUILD"))
                    .cmuxFont(size: 11, weight: .semibold)
                    .foregroundColor(.red)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
    }
}
#endif

struct SidebarEmptyArea: View {
    @EnvironmentObject var tabManager: TabManager
    let rowSpacing: CGFloat
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let dragAutoScrollController: SidebarDragAutoScrollController
    // Value snapshot + closure bundles instead of an @Observable store
    // reference (snapshot-boundary rule).
    let topDropIndicatorVisible: Bool
    var tabDropDelegate: SidebarTabDropDelegate? = nil
    let bonsplitDropIndicator: Binding<SidebarDropIndicator?>
    var expandsVertically = true
    var minimumHeight: CGFloat? = nil

    var body: some View {
        dropTarget
            .overlay {
                SidebarBonsplitTabNewWorkspaceDropOverlay(
                    tabManager: tabManager,
                    selectedTabIds: $selectedTabIds,
                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                    dropIndicator: bonsplitDropIndicator
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .top) {
                if topDropIndicatorVisible {
                    Rectangle()
                        .fill(cmuxAccentColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    @ViewBuilder
    private var dropTarget: some View {
        let base = hitTarget
            .onTapGesture(count: 2) {
                // When the active workspace is a remote-tmux mirror, route through
                // performNewWorkspaceAction so a new workspace becomes a new tmux
                // session instead of a local (orphan) workspace. Gate on the
                // SELECTED tab, not `tabs.contains`: a dedicated remote window can
                // be polluted with a dragged-in local workspace (move targets don't
                // exclude dedicated windows), and `contains` would then misroute a
                // local empty-area double-tap into spawning an unwanted tmux session.
                if tabManager.selectedTab?.isRemoteTmuxMirror == true {
                    _ = AppDelegate.shared?.performNewWorkspaceAction(
                        tabManager: tabManager,
                        debugSource: "sidebar.emptyArea.remoteTmux"
                    )
                } else {
                    tabManager.addWorkspace(placementOverride: .end)
                }
                if let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                }
                selection = .tabs
            }
        if let tabDropDelegate {
            base
                .sidebarEmptyAreaWorkspaceGroupContextMenu(tabManager: tabManager)
                .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: tabDropDelegate)
        } else {
            base
                .sidebarEmptyAreaWorkspaceGroupContextMenu(tabManager: tabManager)
        }
    }

    @ViewBuilder
    private var hitTarget: some View {
        if expandsVertically {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: minimumHeight ?? 0)
                .contentShape(Rectangle())
        }
    }
}

private extension View {
    func sidebarEmptyAreaWorkspaceGroupContextMenu(tabManager: TabManager) -> some View {
        contextMenu {
            let newWorkspaceGroupShortcut = KeyboardShortcutSettings.shortcut(for: .newWorkspaceGroup)
            let newWorkspaceGroupLabel = String(
                localized: "contextMenu.workspaceGroup.newEmpty",
                defaultValue: "New Empty Workspace Group"
            )
            if let key = newWorkspaceGroupShortcut.keyEquivalent {
                Button(newWorkspaceGroupLabel) {
                    _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
                }
                .keyboardShortcut(key, modifiers: newWorkspaceGroupShortcut.eventModifiers)
            } else {
                Button(newWorkspaceGroupLabel) {
                    _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
                }
            }
        }
    }
}

struct ExtensionSidebarBrowserStackEmptyArea: View {
    let rowSpacing: CGFloat
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?
    let onNewTab: () -> Void
    let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture(count: 2, perform: onNewTab)
            .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: ExtensionSidebarBrowserStackEndDropDelegate(
                orderedRows: orderedRows,
                draggedTabId: $draggedTabId,
                dragAutoScrollController: dragAutoScrollController,
                dropIndicator: $dropIndicator,
                onMove: onMove
            ))
            .overlay(alignment: .top) {
                if shouldShowTopDropIndicator {
                    Rectangle()
                        .fill(cmuxAccentColor())
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                        .offset(y: -(rowSpacing / 2))
                }
            }
    }

    private var shouldShowTopDropIndicator: Bool {
        guard let indicator = dropIndicator else { return false }
        if indicator.tabId == nil {
            return true
        }
        guard indicator.edge == .bottom, let lastWorkspaceId = orderedRows.last?.workspaceId else { return false }
        return indicator.tabId == lastWorkspaceId
    }
}

private struct ExtensionSidebarBrowserStackEndDropDelegate: DropDelegate {
    let orderedRows: [ExtensionSidebarBrowserStackDropRow]
    @Binding var draggedTabId: UUID?
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var dropIndicator: SidebarDropIndicator?
    let onMove: (CmuxSidebarProviderWorkspaceMove) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [SidebarTabDragPayload.typeIdentifier])
            && draggedTabId != nil
            && orderedRows.count > 1
    }

    func dropEntered(info: DropInfo) {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator()
    }

    func dropExited(info: DropInfo) {
        if dropIndicator?.tabId == nil {
            dropIndicator = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragAutoScrollController.updateFromDragLocation()
        updateDropIndicator()
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedTabId = nil
            dropIndicator = nil
            dragAutoScrollController.stop()
        }
        guard let draggedTabId,
              let insertionPosition = insertionPositionForEndMove(draggedWorkspaceId: draggedTabId),
              let move = ExtensionSidebarBrowserStackDropPlanner(orderedRows: orderedRows).move(
                draggedWorkspaceId: draggedTabId,
                insertionPosition: insertionPosition
              ) else {
            return false
        }
        return onMove(move)
    }

    private func updateDropIndicator() {
        let workspaceIds = orderedRows.map(\.workspaceId)
        let nextIndicator = SidebarDropPlanner().indicator(
            draggedTabId: draggedTabId,
            targetTabId: nil,
            tabIds: workspaceIds,
            pinnedTabIds: []
        )
        guard dropIndicator != nextIndicator else { return }
        dropIndicator = nextIndicator
    }

    private func insertionPositionForEndMove(draggedWorkspaceId: UUID) -> Int? {
        let workspaceIds = orderedRows.map(\.workspaceId)
        guard workspaceIds.contains(draggedWorkspaceId) else { return nil }
        guard SidebarDropPlanner().indicator(
            draggedTabId: draggedWorkspaceId,
            targetTabId: nil,
            tabIds: workspaceIds,
            pinnedTabIds: []
        ) != nil else {
            return nil
        }
        return workspaceIds.count
    }
}
