import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct WorkspaceListView: View {
    let workspaces: [MobileWorkspacePreview]
    let selectedWorkspaceID: MobileWorkspacePreview.ID?
    let host: String
    let connectionStatus: MobileMacConnectionStatus
    let navigationStyle: WorkspaceNavigationStyle
    let selectWorkspace: (MobileWorkspacePreview.ID) -> Void
    let createWorkspace: () -> Void
    /// Optional: when present, the toolbar shows a "settings" menu offering
    /// "Rescan QR" (disconnect + re-pair) and "Sign out". When nil (e.g.
    /// previews), the menu is hidden.
    var rescanQR: (() -> Void)?
    var signOut: (() -> Void)?
    @State private var searchText = ""
    @State private var showingShortcutsSettings = false
    @State private var showingSettings = false

    private var filteredWorkspaces: [MobileWorkspacePreview] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return workspaces
        }
        return workspaces.filter { workspace in
            workspace.name.localizedCaseInsensitiveContains(query)
                || workspace.previewLine.localizedCaseInsensitiveContains(query)
                || workspace.terminals.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        List {
            if connectionStatus != .connected {
                Section {
                    MobileMacConnectionStatusRow(host: host, status: connectionStatus)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowSeparator(.hidden)
                }
            }
            Section {
                ForEach(filteredWorkspaces) { workspace in
                    WorkspaceNavigationRow(
                        workspace: workspace,
                        host: host,
                        connectionStatus: connectionStatus,
                        isSelected: navigationStyle == .sidebar && selectedWorkspaceID == workspace.id,
                        navigationStyle: navigationStyle,
                        selectWorkspace: selectWorkspace
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
        .mobileInlineNavigationTitle()
        .searchable(text: $searchText)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                settingsMenu
            }
            ToolbarItem(placement: .topBarTrailing) {
                newWorkspaceButton
            }
            #else
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
                connectedHostName: host,
                rescanQR: rescanQR,
                signOut: signOut
            )
        }
        #endif
    }

    private var newWorkspaceButton: some View {
        Button(action: createWorkspace) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(L10n.string("mobile.workspace.new", defaultValue: "New Workspace"))
        .accessibilityIdentifier("MobileNewWorkspaceButton")
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
}
