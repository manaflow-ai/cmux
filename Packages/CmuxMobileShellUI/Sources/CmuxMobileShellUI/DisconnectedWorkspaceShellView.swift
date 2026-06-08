import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct DisconnectedWorkspaceShellView: View {
    let showAddDevice: () -> Void
    let signOut: () -> Void
    /// The shell store, forwarded to the reused Settings sheet so the user can
    /// still switch to another paired Mac from the no-devices/offline state
    /// (this screen is the terminal not-connected state, reached after a stored
    /// Mac reconnect fails). `nil` in previews.
    var store: CMUXMobileShellStore?

    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.devices.emptyTitle", defaultValue: "No devices"),
                    systemImage: "desktopcomputer.and.iphone"
                )
            } description: {
                Text(L10n.string("mobile.devices.emptyDescription", defaultValue: "Add a Mac to start syncing terminal workspaces."))
            } actions: {
                Button(action: showAddDevice) {
                    Text(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityIdentifier("MobileShowAddDeviceButton")
            }
            .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
            .mobileInlineNavigationTitle()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    settingsMenu
                }
                ToolbarItem(placement: .topBarTrailing) {
                    addDeviceToolbarButton
                }
                #else
                ToolbarItem {
                    settingsMenu
                }
                ToolbarItem {
                    addDeviceToolbarButton
                }
                #endif
            }
            .accessibilityIdentifier("MobileDisconnectedWorkspaceShell")
        }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) {
            // Reuse the same Settings sheet the workspace list opens from its
            // 3-dots menu so the no-devices screen's chrome matches. There is no
            // connected host or QR to rescan here, but the store is forwarded so
            // a user whose active Mac went offline can still switch to another
            // paired Mac; the sheet also surfaces the account + Sign Out.
            MobileSettingsView(
                connectedHostName: "",
                rescanQR: nil,
                signOut: signOut,
                store: store
            )
        }
        #endif
    }

    /// The top-left 3-dots overflow, matching ``WorkspaceListView``'s
    /// `settingsMenu` so switching between the connected and no-devices screens
    /// is not jarring. On iOS it opens the full Settings sheet (which holds Sign
    /// Out); on macOS it is an inline menu with Sign Out as an item.
    private var settingsMenu: some View {
        #if os(iOS)
        Button {
            showingSettings = true
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
        .accessibilityIdentifier("MobileWorkspaceSettingsMenu")
        #else
        Menu {
            Button(role: .destructive) {
                signOut()
            } label: {
                Label(
                    L10n.string("mobile.signOut", defaultValue: "Sign Out"),
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
            }
            .accessibilityIdentifier("MobileWorkspaceSignOutMenuItem")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
        .accessibilityIdentifier("MobileWorkspaceSettingsMenu")
        #endif
    }

    private var addDeviceToolbarButton: some View {
        Button(action: showAddDevice) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
        .accessibilityIdentifier("MobileShowAddDeviceToolbarButton")
    }
}
