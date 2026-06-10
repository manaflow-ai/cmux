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

    @Environment(\.tailscaleStatusMonitor) private var tailscaleStatusMonitor

    /// The Founders Edition page (Mac download + TestFlight enrollment) the
    /// onboarding "Download via TestFlight" link points at while TestFlight is
    /// still private.
    private static let testFlightURL = URL(string: "https://github.com/manaflow-ai/cmux#founders-edition")!

    #if os(iOS)
    @State private var isShowingSetupHelp = false
    #endif

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
                Button(action: showAddDevice) {
                    Text(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
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
                Link(
                    L10n.string("mobile.testflight.link", defaultValue: "Download via TestFlight"),
                    destination: Self.testFlightURL
                )
                .font(.callout)
                .accessibilityIdentifier("MobileTestFlightLink")
            }
            .navigationTitle(L10n.string("mobile.workspaces.title", defaultValue: "Workspaces"))
            .mobileInlineNavigationTitle()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    signOutButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    addDeviceToolbarButton
                }
                #else
                ToolbarItem {
                    signOutButton
                }
                ToolbarItem {
                    addDeviceToolbarButton
                }
                #endif
            }
            .accessibilityIdentifier("MobileDisconnectedWorkspaceShell")
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingSetupHelp) {
            // A user on the never-paired/offline screen can reach the same
            // explicit setup-gate guidance shown in onboarding and Settings, so
            // the dead end is never silent. The highlighted gate reflects whether
            // this device has paired a Mac before (offline recovery) or not.
            SetupHelpView(highlight: setupHelpHighlight) { isShowingSetupHelp = false }
        }
        #endif
    }

    private var signOutButton: some View {
        Button(action: signOut) {
            Text(L10n.string("mobile.signOut", defaultValue: "Sign Out"))
        }
        .accessibilityIdentifier("MobileSignOutButton")
    }

    private var addDeviceToolbarButton: some View {
        Button(action: showAddDevice) {
            Image(systemName: "plus")
        }
        .accessibilityLabel(L10n.string("mobile.addDevice.title", defaultValue: "Add device"))
        .accessibilityIdentifier("MobileShowAddDeviceToolbarButton")
    }
}
