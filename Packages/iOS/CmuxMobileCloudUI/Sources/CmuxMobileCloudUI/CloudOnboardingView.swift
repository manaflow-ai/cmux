#if os(iOS)
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Explains the Cloud connection before the first machine is opened.
///
/// The system VPN is optional. cmux's terminal tunnel is app-managed and does
/// not require a VPN permission prompt; the system VPN is only needed when
/// other iOS apps should reach allow-listed VM ports.
public struct CloudOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var page = 0

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TabView(selection: $page) {
                    CloudOnboardingPage(
                        title: L10n.string("mobile.cloud.onboarding.workspace.title", defaultValue: "Your workspace lives in the Cloud"),
                        message: L10n.string("mobile.cloud.onboarding.workspace.message", defaultValue: "Your files, terminals, and coding agents keep running on a Cloud machine when your Mac is asleep or turned off."),
                        systemImage: "cloud.fill",
                        tag: 0
                    )
                    CloudOnboardingPage(
                        title: L10n.string("mobile.cloud.onboarding.key.title", defaultValue: "A private key keeps it private"),
                        message: L10n.string("mobile.cloud.onboarding.key.message", defaultValue: "cmux stores a WireGuard key in this phone's Keychain. Enrollment gives that key permission to join your team's private Cloud network. The key never leaves the phone."),
                        systemImage: "key.fill",
                        tag: 1
                    )
                    CloudOnboardingPage(
                        title: L10n.string("mobile.cloud.onboarding.vpn.title", defaultValue: "Choose how much of the network to expose"),
                        message: L10n.string("mobile.cloud.onboarding.vpn.message", defaultValue: "cmux can connect its own terminal directly. To let Safari, SSH, or another app reach selected VM ports, enable the optional system VPN in Settings."),
                        systemImage: "lock.shield.fill",
                        tag: 2
                    )
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                HStack(spacing: 12) {
                    if page > 0 {
                        Button(L10n.string("mobile.cloud.onboarding.back", defaultValue: "Back")) {
                            withAnimation { page -= 1 }
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    if page < 2 {
                        Button(L10n.string("mobile.cloud.onboarding.continue", defaultValue: "Continue")) {
                            withAnimation { page += 1 }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(L10n.string("mobile.cloud.onboarding.settings", defaultValue: "Open Settings")) {
                            openSystemSettings()
                        }
                        .buttonStyle(.bordered)
                        Button(L10n.string("mobile.cloud.onboarding.done", defaultValue: "Get started")) {
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle(L10n.string("mobile.cloud.onboarding.title", defaultValue: "Cloud basics"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.string("mobile.cloud.onboarding.skip", defaultValue: "Skip")) { dismiss() }
                }
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private struct CloudOnboardingPage: View {
    let title: String
    let message: String
    let systemImage: String
    let tag: Int

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .tag(tag)
        .accessibilityElement(children: .combine)
    }
}
#endif
