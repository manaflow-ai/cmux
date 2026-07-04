#if os(iOS)
import CmuxMobileSupport
import CmuxMobileShell
import CmuxMobileWorkspace
import SwiftUI
import UIKit

struct MobileTroubleshootingSettingsPage: View {
    let rescanQR: (() -> Void)?
    let dismissSettings: () -> Void
    let store: CMUXMobileShellStore?

    @Environment(\.openURL) private var openURL
    @State private var showingOnboarding = false
    @State private var showingSetupHelp = false
    @State private var showingDiagnosticsFromIssue = false
    @State private var expandedIssueIDs: Set<Int> = []

    var body: some View {
        let issues = commonIssues()
        let issueActions = CommonIssueActions(
            toggleExpansion: { id in toggleIssueExpansion(id) },
            openIOSSettings: { openIOSSettings() },
            runDiagnostics: { showingDiagnosticsFromIssue = true }
        )

        Form {
            Section {
                NavigationLink {
                    MobileDiagnosticsSettingsPage(store: store)
                } label: {
                    Label(
                        L10n.string("mobile.settings.runDiagnostics", defaultValue: "Run Diagnostics"),
                        systemImage: "stethoscope"
                    )
                }
                .accessibilityIdentifier("MobileSettingsTroubleshootingRunDiagnostics")
            }

            Section(L10n.string("mobile.troubleshooting.commonIssues", defaultValue: "Common Issues")) {
                ForEach(issues) { issue in
                    CommonIssueDisclosureRow(
                        issue: issue,
                        isExpanded: expandedIssueIDs.contains(issue.id),
                        actions: issueActions
                    )
                }
            }

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
        .navigationDestination(isPresented: $showingDiagnosticsFromIssue) {
            MobileDiagnosticsSettingsPage(store: store)
        }
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

    private func toggleIssueExpansion(_ id: Int) {
        if expandedIssueIDs.contains(id) {
            expandedIssueIDs.remove(id)
        } else {
            expandedIssueIDs.insert(id)
        }
    }

    private func openIOSSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func commonIssues() -> [CommonIssue] {
        [
            CommonIssue(
                id: 1,
                title: L10n.string("mobile.troubleshooting.issue1.title", defaultValue: "My computer doesn't show up"),
                fixes: [
                    L10n.string("mobile.troubleshooting.issue1.fix1", defaultValue: "Confirm Mac and iPhone use the same cmux account."),
                    L10n.string("mobile.troubleshooting.issue1.fix2", defaultValue: "On Mac, allow cmux in System Settings > Privacy & Security > Local Network."),
                    L10n.string("mobile.troubleshooting.issue1.fix3", defaultValue: "Tap Rescan QR, then pair again if needed."),
                    L10n.string("mobile.troubleshooting.issue1.fix4", defaultValue: "Use the same network or Tailscale on both devices."),
                ],
                action: nil
            ),
            CommonIssue(
                id: 2,
                title: L10n.string("mobile.troubleshooting.issue2.title", defaultValue: "Stuck on Still loading"),
                fixes: [
                    L10n.string("mobile.troubleshooting.issue2.fix1", defaultValue: "Open the selected cmux build on your Mac, then tap Retry."),
                    L10n.string("mobile.troubleshooting.issue2.fix2", defaultValue: "If it stays stuck, remove the computer and pair again."),
                ],
                action: nil
            ),
            CommonIssue(
                id: 3,
                title: L10n.string("mobile.troubleshooting.issue3.title", defaultValue: "Notifications don't arrive"),
                fixes: [
                    L10n.string("mobile.troubleshooting.issue3.fix1", defaultValue: "Enable agent notifications in cmux Settings > Notifications."),
                    L10n.string("mobile.troubleshooting.issue3.fix2", defaultValue: "Allow cmux notifications in iOS Settings."),
                    L10n.string("mobile.troubleshooting.issue3.fix3", defaultValue: "Notifications forward only while you're away from your Mac."),
                ],
                action: .openIOSSettings
            ),
            CommonIssue(
                id: 4,
                title: L10n.string("mobile.troubleshooting.issue4.title", defaultValue: "Voice Mode is missing or grayed out"),
                fixes: [
                    L10n.string("mobile.troubleshooting.issue4.fix1", defaultValue: "Update cmux on the Mac; Run Diagnostics should show Voice Mode supported."),
                    L10n.string("mobile.troubleshooting.issue4.fix2", defaultValue: "Click a terminal pane on the Mac before using the mic."),
                ],
                action: .runDiagnostics
            ),
            CommonIssue(
                id: 5,
                title: L10n.string("mobile.troubleshooting.issue5.title", defaultValue: "Voice text goes to the wrong pane"),
                fixes: [
                    L10n.string("mobile.troubleshooting.issue5.fix1", defaultValue: "Voice Mode targets the pane currently focused on the Mac."),
                    L10n.string("mobile.troubleshooting.issue5.fix2", defaultValue: "Click the destination pane before speaking and watch the Target card update."),
                ],
                action: nil
            ),
            CommonIssue(
                id: 6,
                title: L10n.string("mobile.troubleshooting.issue6.title", defaultValue: "Parakeet download fails"),
                fixes: [
                    L10n.string("mobile.troubleshooting.issue6.fix1", defaultValue: "Keep about 483 MB free and use a stable connection."),
                    L10n.string("mobile.troubleshooting.issue6.fix2", defaultValue: "Cancel and retry the download."),
                    L10n.string("mobile.troubleshooting.issue6.fix3", defaultValue: "If transcription misbehaves, delete the model in Settings > Voice and download again."),
                ],
                action: nil
            ),
            CommonIssue(
                id: 7,
                title: L10n.string("mobile.troubleshooting.issue7.title", defaultValue: "Microphone or dictation doesn't work"),
                fixes: [
                    L10n.string("mobile.troubleshooting.issue7.fix1", defaultValue: "Allow Microphone for cmux in iOS Settings > Privacy & Security."),
                    L10n.string("mobile.troubleshooting.issue7.fix2", defaultValue: "For Apple engine, allow Speech Recognition too, then retry the mic."),
                ],
                action: .openIOSSettings
            ),
            CommonIssue(
                id: 8,
                title: L10n.string("mobile.troubleshooting.issue8.title", defaultValue: "Connection keeps dropping"),
                fixes: [
                    L10n.string("mobile.troubleshooting.issue8.fix1", defaultValue: "Check Connection in Run Diagnostics."),
                    L10n.string("mobile.troubleshooting.issue8.fix2", defaultValue: "Toggle Wi-Fi or switch networks to force a reconnect."),
                    L10n.string("mobile.troubleshooting.issue8.fix3", defaultValue: "If it stays down, reconnect from the computer picker."),
                ],
                action: .runDiagnostics
            ),
        ]
    }
}

private struct CommonIssue: Identifiable {
    let id: Int
    let title: String
    let fixes: [String]
    let action: CommonIssueAction?
}

private enum CommonIssueAction {
    case openIOSSettings
    case runDiagnostics
}

private struct CommonIssueActions {
    let toggleExpansion: (Int) -> Void
    let openIOSSettings: () -> Void
    let runDiagnostics: () -> Void
}

private struct CommonIssueDisclosureRow: View {
    let issue: CommonIssue
    let isExpanded: Bool
    let actions: CommonIssueActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                actions.toggleExpansion(issue.id)
            } label: {
                HStack {
                    Text(issue.title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                issueBody
            }
        }
        .accessibilityIdentifier("MobileTroubleshootingIssue\(issue.id)")
    }

    private var issueBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(issue.fixes.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(issue.fixes[index])
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            actionButton
                .padding(.top, 2)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch issue.action {
        case .openIOSSettings:
            Button {
                actions.openIOSSettings()
            } label: {
                Label(
                    L10n.string("mobile.troubleshooting.openIOSSettings", defaultValue: "Open iOS Settings"),
                    systemImage: "gear"
                )
            }
            .font(.callout)
            .accessibilityIdentifier("MobileTroubleshootingIssue\(issue.id)OpenIOSSettings")
        case .runDiagnostics:
            Button {
                actions.runDiagnostics()
            } label: {
                Label(
                    L10n.string("mobile.settings.runDiagnostics", defaultValue: "Run Diagnostics"),
                    systemImage: "stethoscope"
                )
            }
            .font(.callout)
            .accessibilityIdentifier("MobileTroubleshootingIssue\(issue.id)RunDiagnostics")
        case .none:
            EmptyView()
        }
    }
}
#endif
