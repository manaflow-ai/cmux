import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI
#if os(iOS)
@preconcurrency import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The screen shown when the phone has no live connection to a Mac.
///
/// It communicates *why* there is no connection so the user knows what to do:
/// guide a never-paired device to pairing, tell a known-but-unreachable Mac it
/// is offline or asleep (with a reconnect control), and show a bounded indicator
/// while a reconnect attempt is in flight. The state is classified upstream by
/// ``DisconnectedShellPolicy`` so this view only renders.
struct DisconnectedWorkspaceShellView: View {
    /// Why we are disconnected (never paired, known-but-offline, reconnecting).
    let state: DisconnectedShellState
    /// Display name of the known Mac, when one is on record, for the offline copy.
    let macName: String?
    let showAddDevice: () -> Void
    let reconnect: () -> Void
    let signOut: () -> Void

    /// The Founders Edition page (Mac download + TestFlight enrollment) the
    /// onboarding "Download via TestFlight" link points at while TestFlight is
    /// still private.
    private static let testFlightURL = URL(string: "https://github.com/manaflow-ai/cmux#founders-edition")!

    var body: some View {
        NavigationStack {
            content
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
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .neverPaired:
            neverPairedContent
        case .offline:
            offlineContent
        case .reconnecting:
            reconnectingContent
        }
    }

    /// No Mac on record: guide the user to pair one. There is nothing to
    /// reconnect to, so this never shows a reconnect control or a spinner.
    @ViewBuilder
    private var neverPairedContent: some View {
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
            Link(
                L10n.string("mobile.testflight.link", defaultValue: "Download via TestFlight"),
                destination: Self.testFlightURL
            )
            .font(.callout)
            .accessibilityIdentifier("MobileTestFlightLink")
        }
        .accessibilityIdentifier("MobileDisconnectedNeverPaired")
    }

    /// A known Mac is unreachable (offline, asleep, or its route went stale).
    /// Name it when we can, and offer Reconnect so the user can retry without
    /// waiting on the next automatic attempt.
    @ViewBuilder
    private var offlineContent: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.disconnected.offlineTitle", defaultValue: "Mac is offline or asleep"),
                systemImage: "desktopcomputer.trianglebadge.exclamationmark"
            )
        } description: {
            Text(offlineDescription)
        } actions: {
            Button(action: reconnect) {
                Text(L10n.string("mobile.disconnected.reconnect", defaultValue: "Reconnect"))
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .accessibilityIdentifier("MobileDisconnectedReconnectButton")
            Button(action: showAddDevice) {
                Text(L10n.string("mobile.disconnected.pairAnother", defaultValue: "Pair another Mac"))
            }
            .font(.callout)
            .accessibilityIdentifier("MobileDisconnectedPairAnotherButton")
        }
        .accessibilityIdentifier("MobileDisconnectedOffline")
    }

    private var offlineDescription: String {
        if let macName, !macName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(
                format: L10n.string(
                    "mobile.disconnected.offlineDescriptionNamed",
                    defaultValue: "Can't reach %@. Open cmux on the Mac or wake the computer, then reconnect."
                ),
                macName
            )
        }
        return L10n.string(
            "mobile.disconnected.offlineDescription",
            defaultValue: "Open cmux on the Mac or wake the computer, then reconnect."
        )
    }

    /// A reconnect attempt is actively running: a bounded, indeterminate
    /// indicator. The attempt resolves on its own (success flips to the
    /// workspaces; failure falls through to the offline state), so this never
    /// shows a manual control.
    @ViewBuilder
    private var reconnectingContent: some View {
        ContentUnavailableView {
            Label {
                Text(L10n.string("mobile.disconnected.reconnectingTitle", defaultValue: "Reconnecting…"))
            } icon: {
                ProgressView()
            }
        } description: {
            Text(L10n.string("mobile.disconnected.reconnectingDescription", defaultValue: "Trying to reach your Mac."))
        }
        .accessibilityIdentifier("MobileDisconnectedReconnecting")
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
