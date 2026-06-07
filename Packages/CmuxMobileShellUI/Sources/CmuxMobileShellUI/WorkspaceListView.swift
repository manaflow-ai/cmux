import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The aggregated all-devices workspace list, grouped by source Mac.
///
/// Renders one `List` with a section per paired Mac (header = device name +
/// status dot; the offline group reuses ``MobileMacConnectionStatusRow``), a
/// device filter that composes with search, and a pull-to-refresh that re-pulls
/// every Mac's list. Sections and rows receive value snapshots
/// (``MobileWorkspaceDeviceSection``) plus action closures only, so nothing below
/// the list holds the shell store (the snapshot-boundary rule). The store is
/// forwarded solely into the Settings sheet, which sits above the list content.
struct WorkspaceListView: View {
    /// Value snapshots of the aggregated list, grouped by source Mac.
    let deviceSections: [MobileWorkspaceDeviceSection]
    let selectedWorkspaceID: MobileWorkspacePreview.ID?
    let navigationStyle: WorkspaceNavigationStyle
    /// Select a workspace by `(workspaceID, sourceMacDeviceID)` so a tap resolves
    /// to the right Mac's partition under a cross-Mac id collision.
    let selectWorkspace: (MobileWorkspacePreview.ID, String) -> Void
    let createWorkspace: () -> Void
    /// Re-pull every paired Mac's list (pull-to-refresh / filter change).
    var refreshAllDevices: (() async -> Void)?
    /// Optional: when present, the toolbar shows a "settings" menu offering
    /// "Rescan QR" (disconnect + re-pair) and "Sign out". When nil (e.g.
    /// previews), the menu is hidden.
    var rescanQR: (() -> Void)?
    var signOut: (() -> Void)?
    /// The shell store, forwarded to Settings to drive the multi-Mac switcher.
    /// `nil` in previews. Held only to seed the Settings sheet, which is above
    /// the list content; rows/sections never see it.
    var store: CMUXMobileShellStore?
    /// Optional: rename a workspace on the Mac. When present, each row offers a
    /// Rename context-menu action.
    var renameWorkspace: ((MobileWorkspacePreview.ID, String) -> Void)?
    /// Optional: pin/unpin a workspace on the Mac. When present, each row offers
    /// a Pin/Unpin context-menu action and pinned workspaces sort to the top.
    var setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)?
    @State private var searchText = ""
    @State private var deviceFilter: WorkspaceDeviceFilter = .all
    @State private var showingShortcutsSettings = false
    @State private var showingSettings = false

    /// Sections after the device filter and search, with pinned workspaces first
    /// within each Mac. Empty sections (no matching workspace) are dropped.
    private var visibleSections: [MobileWorkspaceDeviceSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return deviceSections.compactMap { section -> MobileWorkspaceDeviceSection? in
            guard deviceFilter.matches(deviceID: section.deviceID) else { return nil }
            let matches = Self.filteredWorkspaces(section.workspaces, query: query)
            guard !matches.isEmpty else { return nil }
            var filtered = section
            filtered.workspaces = matches
            return filtered
        }
    }

    /// The connected host name for the active Mac, for the per-row host detail.
    private var activeHostName: String {
        deviceSections.first(where: \.isActive)?.displayName ?? ""
    }

    var body: some View {
        List {
            ForEach(visibleSections) { section in
                // Rename/pin send over the single heavy session's `remoteClient`,
                // which is always the active Mac. Offering those actions on a
                // non-active or unreachable section would route the mutation to
                // the wrong Mac (or, under a cross-Mac id collision, mutate the
                // active Mac's workspace). Phase 1 scopes the affordance to the
                // active+reachable section; tap a Mac's workspace to activate it
                // before renaming/pinning. Live secondary actions are Phase 2.
                let sectionAllowsActions = section.isActive && section.isReachable
                Section {
                    ForEach(section.workspaces) { workspace in
                        WorkspaceNavigationRow(
                            workspace: workspace,
                            host: section.displayName,
                            connectionStatus: section.status,
                            isSelected: navigationStyle == .sidebar && selectedWorkspaceID == workspace.id,
                            navigationStyle: navigationStyle,
                            selectWorkspace: selectWorkspace,
                            renameWorkspace: sectionAllowsActions ? renameWorkspace : nil,
                            setPinned: sectionAllowsActions ? setPinned : nil
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    sectionHeader(for: section)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
        .mobileInlineNavigationTitle()
        .searchable(text: $searchText)
        .refreshable {
            await refreshAllDevices?()
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                settingsMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 2) {
                    deviceFilterMenu
                    newWorkspaceButton
                }
            }
            #else
            ToolbarItem {
                deviceFilterMenu
            }
            ToolbarItem {
                newWorkspaceButton
            }
            #endif
        }
        .accessibilityIdentifier("MobileWorkspaceList")
        #if os(iOS)
        .sheet(isPresented: $showingShortcutsSettings) {
            TerminalShortcutsSettingsView()
        }
        .sheet(isPresented: $showingSettings) {
            MobileSettingsView(
                connectedHostName: activeHostName,
                rescanQR: rescanQR,
                signOut: signOut,
                store: store
            )
        }
        #endif
    }

    @ViewBuilder
    private func sectionHeader(for section: MobileWorkspaceDeviceSection) -> some View {
        if section.isReachable {
            HStack(spacing: 8) {
                Circle()
                    .fill(section.status.tintColor)
                    .frame(width: 8, height: 8)
                Text(section.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("MobileDeviceSectionHeader-\(section.deviceID)")
        } else {
            // Offline / reconnecting Macs reuse the richer status row so the
            // user sees why the section is grayed, not just a dimmed name.
            MobileMacConnectionStatusRow(host: section.displayName, status: section.status)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .accessibilityIdentifier("MobileDeviceSectionHeader-\(section.deviceID)")
        }
    }

    private var newWorkspaceButton: some View {
        Button(action: createWorkspace) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
        .accessibilityIdentifier("MobileNewWorkspaceButton")
    }

    /// Filter the aggregated list to one Mac (or all). Replaces the old "switch
    /// the active Mac in Settings" model: the user picks which Mac's workspaces
    /// to view in one place, and tapping a workspace handles activation.
    private var deviceFilterMenu: some View {
        Menu {
            Button {
                setDeviceFilter(.all)
            } label: {
                filterLabel(
                    title: L10n.string("mobile.deviceFilter.all", defaultValue: "All Devices"),
                    isSelected: deviceFilter == .all
                )
            }
            .accessibilityIdentifier("MobileDeviceFilterAll")

            if !deviceSections.isEmpty {
                Divider()
                ForEach(deviceSections) { section in
                    Button {
                        setDeviceFilter(.device(section.deviceID))
                    } label: {
                        filterLabel(
                            title: section.displayName,
                            isSelected: deviceFilter == .device(section.deviceID)
                        )
                    }
                    .accessibilityIdentifier("MobileDeviceFilter-\(section.deviceID)")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(L10n.string("mobile.deviceFilter.label", defaultValue: "Filter by device"))
        .accessibilityIdentifier("MobileDeviceFilterMenu")
    }

    @ViewBuilder
    private func filterLabel(title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func setDeviceFilter(_ filter: WorkspaceDeviceFilter) {
        deviceFilter = filter
        // Tapping a device in the filter is a freshness intent: re-pull every
        // Mac's list so the chosen device shows current state.
        Task { await refreshAllDevices?() }
    }

    private var settingsMenu: some View {
        #if os(iOS)
        // Open the full Settings page (account, terminal shortcuts,
        // notifications, paired Mac) rather than a transient menu.
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
        .accessibilityIdentifier("MobileWorkspaceSettingsMenu")
        #else
        Menu {
            Button {
                showingShortcutsSettings = true
            } label: {
                Label(
                    L10n.string("mobile.workspaces.terminalShortcuts", defaultValue: "Terminal Shortcuts"),
                    systemImage: "keyboard"
                )
            }
            .accessibilityIdentifier("MobileWorkspaceTerminalShortcutsMenuItem")
            if let rescanQR {
                Button {
                    rescanQR()
                } label: {
                    Label(
                        L10n.string("mobile.workspaces.rescan", defaultValue: "Rescan QR"),
                        systemImage: "qrcode.viewfinder"
                    )
                }
                .accessibilityIdentifier("MobileWorkspaceRescanQRMenuItem")
            }
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

    /// Workspaces matching the search query, pinned ones first (stable within
    /// each group so the Mac's order is otherwise preserved).
    private static func filteredWorkspaces(
        _ workspaces: [MobileWorkspacePreview],
        query: String
    ) -> [MobileWorkspacePreview] {
        let matches: [MobileWorkspacePreview]
        if query.isEmpty {
            matches = workspaces
        } else {
            matches = workspaces.filter { workspace in
                workspace.name.localizedCaseInsensitiveContains(query)
                    || workspace.previewLine.localizedCaseInsensitiveContains(query)
                    || workspace.terminals.contains { $0.name.localizedCaseInsensitiveContains(query) }
            }
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
}
