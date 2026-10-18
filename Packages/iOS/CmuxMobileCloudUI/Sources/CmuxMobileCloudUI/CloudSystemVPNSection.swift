#if os(iOS)
import CmuxMobileCloud
import CmuxMobileSupport
import SwiftUI

/// The opt-in system VPN switch in the Cloud tab.
///
/// HIG: Toggles (a switch in an inset-grouped row, its effect explained in
/// the section footer) and Privacy (the footer says iOS asks permission and
/// what the VPN routes before the user turns it on).
///
/// Takes a value and closures, not the controller, so the row stays
/// independent of the observable store it is rendered from.
struct CloudSystemVPNSection: View {
    let phase: CloudSystemVPNPhase
    let isAvailable: Bool
    let enable: () -> Void
    let disable: () -> Void
    let retry: () -> Void
    @State private var isInfoPresented = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { phase.isRequestedOn },
                set: { $0 ? enable() : disable() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("mobile.cloud.vpn.title", defaultValue: "System VPN"))
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("CloudVPNStatus")
                }
            }
            .disabled(isToggleDisabled)
            .accessibilityIdentifier("CloudVPNToggle")

            if case .failed(let error) = phase, isAvailable {
                Text(failureMessage(error))
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("CloudVPNFailure")
                Button(L10n.string("mobile.cloud.vpn.retry", defaultValue: "Try Again"), action: retry)
                    .accessibilityIdentifier("CloudVPNRetry")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if isAvailable {
                    Text(L10n.string(
                        "mobile.cloud.vpn.privateAddresses",
                        defaultValue: "Lets Safari and other apps reach your Cloud machines' private addresses."
                    ))
                    Button(L10n.string("mobile.cloud.vpn.learnMore", defaultValue: "Learn more")) {
                        isInfoPresented = true
                    }
                    .accessibilityIdentifier("CloudVPNLearnMore")
                    Text(L10n.string(
                        "mobile.cloud.vpn.footer",
                        defaultValue: "Terminals work without it. iOS asks for permission the first time, and turning it on can disconnect another VPN."
                    ))
                } else {
                    Text(L10n.string(
                        "mobile.cloud.vpn.deviceRequired",
                        defaultValue: "System VPN needs a physical iPhone or iPad."
                    ))
                }
            }
        }
        .sheet(isPresented: $isInfoPresented) {
            CloudSystemVPNInfoSheet()
        }
    }

    var isToggleDisabled: Bool {
        !isAvailable || phase.isTransitioning
    }

    private var statusText: String {
        switch phase {
        case .off, .failed:
            L10n.string("mobile.cloud.vpn.status.off", defaultValue: "Off")
        case .preparing:
            L10n.string("mobile.cloud.vpn.status.preparing", defaultValue: "Setting up…")
        case .connecting:
            L10n.string("mobile.cloud.vpn.status.connecting", defaultValue: "Connecting…")
        case .connected:
            L10n.string("mobile.cloud.vpn.status.connected", defaultValue: "Connected")
        case .disconnecting:
            L10n.string("mobile.cloud.vpn.status.disconnecting", defaultValue: "Disconnecting…")
        }
    }

    private func failureMessage(_ error: CloudSystemVPNError) -> String {
        switch error {
        case .unavailable:
            L10n.string("mobile.cloud.vpn.deviceRequired", defaultValue: "System VPN needs a physical iPhone or iPad.")
        case .enrollment:
            L10n.string(
                "mobile.cloud.vpn.enrollmentFailed",
                defaultValue: "Cloud couldn't register this device for the VPN."
            )
        case .permissionRequired:
            L10n.string(
                "mobile.cloud.vpn.permissionRequired",
                defaultValue: "iOS didn't save the VPN. Try again and choose Allow when iOS asks."
            )
        case .configuration:
            L10n.string(
                "mobile.cloud.vpn.failed",
                defaultValue: "The VPN couldn't start. Try again, or check it in Settings > General > VPN & Device Management."
            )
        }
    }
}

private struct CloudSystemVPNInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    CloudVPNInfoVisual()
                    Text(L10n.string(
                        "mobile.cloud.vpn.sheet.body",
                        defaultValue: "A Cloud machine can run a private web service, such as a development server on port 3000. With System VPN on, Safari can open that private address as if the phone were on the machine's network."
                    ))
                    .font(.body)
                    Text(L10n.string(
                        "mobile.cloud.vpn.sheet.footer",
                        defaultValue: "Terminal connections use their own secure path, so they do not need this switch. System VPN only adds access for Safari and other apps."
                    ))
                    .font(.body)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .navigationTitle(L10n.string(
                "mobile.cloud.vpn.sheet.title",
                defaultValue: "How System VPN works"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct CloudVPNInfoVisual: View {
    var body: some View {
        HStack(spacing: 10) {
            infoIcon("safari.fill", color: .blue)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            infoIcon("lock.network", color: .green)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            infoIcon("server.rack", color: .orange)
        }
        .font(.title2)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityLabel(L10n.string(
            "mobile.cloud.vpn.sheet.visual",
            defaultValue: "Safari reaches a private service through System VPN"
        ))
    }

    private func infoIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .foregroundStyle(color)
            .frame(width: 48, height: 48)
    }
}
#endif
