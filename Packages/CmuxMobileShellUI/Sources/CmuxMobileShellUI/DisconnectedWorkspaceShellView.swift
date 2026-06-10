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
    /// Builds a connection doctor for the "Connection checkup" entrance.
    let makeConnectionDoctor: @MainActor () -> ConnectionDoctor

    @State private var isShowingConnectionDoctor = false

    /// The Founders Edition page (Mac download + TestFlight enrollment) the
    /// onboarding "Download via TestFlight" link points at while TestFlight is
    /// still private.
    private static let testFlightURL = URL(string: "https://github.com/manaflow-ai/cmux#founders-edition")!

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
                Button {
                    isShowingConnectionDoctor = true
                } label: {
                    Text(L10n.string("mobile.doctor.entry", defaultValue: "Connection checkup"))
                }
                .font(.callout)
                .accessibilityIdentifier("MobileDisconnectedConnectionDoctorButton")
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
        .sheet(isPresented: $isShowingConnectionDoctor) {
            ConnectionDoctorView(
                makeDoctor: makeConnectionDoctor,
                done: { isShowingConnectionDoctor = false }
            )
        }
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
