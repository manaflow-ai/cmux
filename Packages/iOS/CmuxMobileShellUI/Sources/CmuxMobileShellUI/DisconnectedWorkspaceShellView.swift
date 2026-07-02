import CmuxMobilePairedMac
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

struct DisconnectedWorkspaceShellView: View {
    /// Whether this install has ever paired a Mac. Gates the
    /// Tailscale-inactive callout: its copy explains an unreachable Mac, which
    /// is misleading for a signed-in user who has not added a device yet (that
    /// user gets the pairing-flavored callout in the auto-presented sheet).
    let hasKnownPairedMac: Bool
    let showAddDevice: () -> Void
    let signOut: () -> Void
    /// The setup gate to highlight in the "Trouble connecting?" help (iOS only).
    /// The root passes `.macUnreachable` for a returning device whose stored Mac
    /// just failed to reconnect, and `.signedInNeverPaired` for a device that has
    /// never paired, so the help marks the user's real recovery step.
    var setupHelpHighlight: MobileSetupGuidanceState = .signedInNeverPaired
    /// The shell store, forwarded to the reused Settings sheet so the user can
    /// still switch to another paired Mac from the no-devices/offline state
    /// (this screen is the terminal not-connected state, reached after a stored
    /// Mac reconnect fails). `nil` in previews.
    var store: CMUXMobileShellStore?

    @Environment(\.tailscaleStatusMonitor) private var tailscaleStatusMonitor

    @State private var showingSettings = false

    /// Saved Macs restored/known on this device. Surfaced here so a returning or
    /// freshly-restored user can pick a known Mac directly instead of being
    /// dropped into the bare "add device" pairing flow when auto-reconnect did
    /// not land (e.g. the Mac is momentarily unreachable).
    private var savedMacs: [MobilePairedMac] { store?.pairedMacs ?? [] }

    #if os(iOS)
    @State private var isShowingSetupHelp = false
    #endif

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(
                    savedMacs.isEmpty
                        ? L10n.string("mobile.devices.emptyTitle", defaultValue: "No devices")
                        : L10n.string("mobile.devices.savedTitle", defaultValue: "Your Computers"),
                    systemImage: "desktopcomputer.and.iphone"
                )
            } description: {
                Text(
                    savedMacs.isEmpty
                        ? L10n.string("mobile.devices.emptyDescription", defaultValue: "Add a computer to start syncing terminal workspaces.")
                        : L10n.string("mobile.devices.savedDescription", defaultValue: "Tap a saved computer to reconnect, or add another.")
                )
            } actions: {
                // When a paired Mac is unreachable and this device has no
                // active tailnet, lead with that explanation instead of
                // leaving the user staring at a generic empty state. Skip it
                // when no Mac was ever paired: the disconnected copy assumes a
                // Mac exists, and the pairing sheet carries its own callout.
                if hasKnownPairedMac, tailscaleStatusMonitor?.status == .inactiveOrNotInstalled {
                    TailscaleInactiveCallout(context: .disconnected)
                        .frame(maxWidth: 320, alignment: .leading)
                        .padding(.bottom, 4)
                }
                // Restored/known saved Macs, tappable to reconnect. A small fixed
                // set (bounded by the per-user backup cap), so a plain VStack is
                // fine; rows take value snapshots + a closure action, never the
                // store, honoring the list snapshot-boundary rule.
                if let store, !savedMacs.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(savedMacs) { mac in
                            Button {
                                Task { await store.switchToMac(macDeviceID: mac.macDeviceID) }
                            } label: {
                                Label(mac.displayName ?? mac.macDeviceID, systemImage: "desktopcomputer")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("MobileDisconnectedSavedMac-\(mac.macDeviceID)")
                        }
                    }
                    .frame(maxWidth: 320)
                    .padding(.bottom, 4)
                }
                Button(action: showAddDevice) {
                    Text(
                        savedMacs.isEmpty
                            ? L10n.string("mobile.addDevice.title", defaultValue: "Add Computer")
                            : L10n.string("mobile.addDevice.another", defaultValue: "Add another Computer")
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityIdentifier("MobileShowAddDeviceButton")
                #if os(iOS)
                Button {
                    isShowingSetupHelp = true
                } label: {
                    Text(L10n.string("mobile.devices.setupHelp", defaultValue: "Trouble connecting?"))
                }
                .font(.callout)
                .accessibilityIdentifier("MobileDisconnectedSetupHelpButton")
                #endif
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
            .task {
                // Load (and, via the backup decorator, restore) saved Macs so a
                // known/restored Mac shows up here for one-tap reconnect. Only
                // auto-present the pairing sheet when there is nothing to pick,
                // so a returning user is not buried under the add-device flow.
                await store?.loadPairedMacs()
                if store?.pairedMacs.isEmpty ?? true {
                    showAddDevice()
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingSetupHelp) {
            // A user on the never-paired/offline screen can reach the same
            // explicit setup-gate guidance shown in onboarding and Settings, so
            // the dead end is never silent. The highlighted gate reflects whether
            // this device has paired a Mac before (offline recovery) or not.
            SetupHelpView(highlight: setupHelpHighlight) { isShowingSetupHelp = false }
        }
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
        .accessibilityLabel(L10n.string("mobile.addDevice.title", defaultValue: "Add Computer"))
        .accessibilityIdentifier("MobileShowAddDeviceToolbarButton")
    }
}
