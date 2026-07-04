#if os(iOS)
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI

struct MobileTroubleshootingSettingsPage: View {
    let rescanQR: (() -> Void)?
    let dismissSettings: () -> Void

    @State private var showingOnboarding = false
    @State private var showingSetupHelp = false

    var body: some View {
        Form {
            Section {
                Button {
                    showingSetupHelp = true
                } label: {
                    Label(
                        L10n.string("mobile.settings.setUpYourMac", defaultValue: "Set Up Computer"),
                        systemImage: "macbook.and.iphone"
                    )
                }
                .accessibilityIdentifier("MobileSettingsSetUpYourMac")

                Button {
                    showingOnboarding = true
                } label: {
                    Label(
                        L10n.string("mobile.settings.howPairingWorks", defaultValue: "How Pairing Works"),
                        systemImage: "questionmark.circle"
                    )
                }
                .accessibilityIdentifier("MobileSettingsHowPairingWorks")

                if let rescanQR {
                    Button {
                        rescanQR()
                        dismissSettings()
                    } label: {
                        Label(
                            L10n.string("mobile.workspaces.rescan", defaultValue: "Rescan QR"),
                            systemImage: "qrcode.viewfinder"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsTroubleshootingRescanQR")
                }

                Link(destination: URL(string: "mailto:founders@manaflow.com")!) {
                    Label(
                        L10n.string("mobile.settings.contactSupport", defaultValue: "Contact Support"),
                        systemImage: "envelope"
                    )
                }
                .accessibilityIdentifier("MobileSettingsTroubleshootingContactSupport")
            }
        }
        .navigationTitle(L10n.string("mobile.settings.troubleshooting", defaultValue: "Troubleshooting"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingOnboarding) {
            OnboardingFlowView(
                onComplete: { showingOnboarding = false },
                setupHelpHighlight: nil
            )
        }
        .sheet(isPresented: $showingSetupHelp) {
            SetupHelpView(highlight: nil) { showingSetupHelp = false }
        }
        .accessibilityIdentifier("MobileSettingsTroubleshootingPage")
    }
}
#endif
