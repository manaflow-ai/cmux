#if os(iOS)
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// The mobile app's settings page. Surfaces account, team, connection, and
/// grouped settings pages from a compact root list.
struct MobileSettingsView: View {
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(MobileDisplaySettings.self) private var displaySettings
    let connectedHostName: String
    let rescanQR: (() -> Void)?
    let signOut: (() -> Void)?
    /// The shell store, used to drive the multi-Mac switcher. `nil` in previews,
    /// where the "Switch Computer" and Voice Mode entries are hidden.
    var store: CMUXMobileShellStore?

    @Environment(\.dismiss) private var dismiss
    @State private var showingHostPicker = false
    @State private var showingVoiceMode = false
    #if DEBUG
    @State private var showingChatDemo = false
    @State private var showingTerminalDemo = false
    #endif

    var body: some View {
        @Bindable var displaySettings = displaySettings
        return NavigationStack {
            Form {
                accountSection
                teamSection
                connectionSection
                settingsPagesSection

                #if DEBUG
                Section(L10n.string("mobile.settings.developer", defaultValue: "Developer")) {
                    Button {
                        showingChatDemo = true
                    } label: {
                        Label(
                            L10n.string("mobile.settings.agentChatDemo", defaultValue: "Agent Chat Demo"),
                            systemImage: "bubble.left.and.bubble.right"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsAgentChatDemo")

                    Button {
                        showingTerminalDemo = true
                    } label: {
                        Label(
                            L10n.string("mobile.settings.terminalLogDemo", defaultValue: "Terminal Log Demo"),
                            systemImage: "terminal"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsTerminalLogDemo")

                    debugLayoutSlider(
                        title: L10n.string(
                            "mobile.settings.unreadIndicatorLeftness",
                            defaultValue: "Unread Indicator Leftness"
                        ),
                        value: $displaySettings.unreadIndicatorLeftShift,
                        range: MobileDisplaySettings.unreadIndicatorLeftShiftRange,
                        identifier: "MobileSettingsUnreadIndicatorLeftness"
                    )
                    debugLayoutSlider(
                        title: L10n.string(
                            "mobile.settings.profilePictureLeftness",
                            defaultValue: "Profile Picture Leftness"
                        ),
                        value: $displaySettings.profilePictureLeftShift,
                        range: MobileDisplaySettings.profilePictureLeftShiftRange,
                        identifier: "MobileSettingsProfilePictureLeftness"
                    )
                    debugLayoutSlider(
                        title: L10n.string(
                            "mobile.settings.profilePictureSize",
                            defaultValue: "Profile Picture Size"
                        ),
                        value: $displaySettings.profilePictureSize,
                        range: MobileDisplaySettings.profilePictureSizeRange,
                        identifier: "MobileSettingsProfilePictureSize"
                    )
                }
                #endif
            }
            .navigationDestination(for: MobileSettingsRoute.self) { route in
                switch route {
                case .terminal:
                    MobileTerminalSettingsPage()
                case .browser:
                    MobileBrowserSettingsPage()
                case .voice:
                    MobileVoiceSettingsPage(
                        canOpenVoiceMode: store?.supportsVoiceMode == true && !connectedHostName.isEmpty,
                        openVoiceMode: { showingVoiceMode = true }
                    )
                case .notifications:
                    MobileNotificationsSettingsPage()
                case .about:
                    MobileAboutSettingsPage()
                case .privacy:
                    MobilePrivacySettingsPage()
                case .troubleshooting:
                    MobileTroubleshootingSettingsPage(
                        rescanQR: rescanQR,
                        dismissSettings: { dismiss() }
                    )
                }
            }
            .navigationTitle(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.settings.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileSettingsDone")
                }
            }
            #if DEBUG
            .fullScreenCover(isPresented: $showingChatDemo) {
                AgentChatDemoScreen()
            }
            .fullScreenCover(isPresented: $showingTerminalDemo) {
                TerminalLogDemoScreen()
            }
            #endif
            .sheet(isPresented: $showingHostPicker) {
                if let store {
                    MobileHostPickerView(store: store)
                }
            }
            .fullScreenCover(isPresented: $showingVoiceMode) {
                if let store {
                    VoiceModeView(store: store, connectedHostName: connectedHostName)
                }
            }
        }
        .accessibilityIdentifier("MobileSettingsView")
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            LabeledContent {
                Text(accountEmail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Label(accountDisplayName, systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("MobileSettingsAccountRow")

            if let signOut {
                Button(role: .destructive) {
                    signOut()
                    dismiss()
                } label: {
                    Label(
                        L10n.string("mobile.signOut", defaultValue: "Sign Out"),
                        systemImage: "rectangle.portrait.and.arrow.right"
                    )
                }
                .accessibilityIdentifier("MobileSettingsSignOut")
            }
        } header: {
            Text(L10n.string("mobile.settings.account", defaultValue: "Account"))
        } footer: {
            Text(L10n.string(
                "mobile.settings.accountFooter",
                defaultValue: "This device must be signed in to the same cmux account as the computer you pair with."
            ))
        }
    }

    @ViewBuilder
    private var teamSection: some View {
        if authManager.availableTeams.count > 1 {
            Section {
                Picker(selection: teamSelection) {
                    ForEach(authManager.availableTeams) { team in
                        Text(team.displayName).tag(team.id as String?)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("MobileSettingsTeamPicker")
            } header: {
                Label(
                    L10n.string("mobile.settings.team", defaultValue: "Team"),
                    systemImage: "person.2"
                )
            } footer: {
                Text(L10n.string(
                    "mobile.settings.teamFooter",
                    defaultValue: "Switches which Stack team's computers and devices this app shows."
                ))
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        if hasConnectionSection {
            Section(L10n.string("mobile.settings.connection", defaultValue: "Connection")) {
                if !connectedHostName.isEmpty {
                    LabeledContent(
                        L10n.string("mobile.settings.mac", defaultValue: "Computer"),
                        value: connectedHostName
                    )
                    .accessibilityIdentifier("MobileSettingsComputerRow")
                }

                if store != nil {
                    Button {
                        showingHostPicker = true
                    } label: {
                        Label(
                            L10n.string("mobile.settings.switchMac", defaultValue: "Switch Computer"),
                            systemImage: "macbook.and.iphone"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsSwitchMac")
                }

                if let rescanQR {
                    Button {
                        rescanQR()
                        dismiss()
                    } label: {
                        Label(
                            L10n.string("mobile.workspaces.rescan", defaultValue: "Rescan QR"),
                            systemImage: "qrcode.viewfinder"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsRescanQR")
                }
            }
        }
    }

    private var settingsPagesSection: some View {
        Section {
            settingsPageLink(
                .terminal,
                title: L10n.string("mobile.settings.terminal", defaultValue: "Terminal"),
                systemImage: "terminal",
                identifier: "MobileSettingsTerminalRow"
            )
            settingsPageLink(
                .browser,
                title: L10n.string("mobile.settings.browser", defaultValue: "Browser"),
                systemImage: "globe",
                identifier: "MobileSettingsBrowserRow"
            )
            settingsPageLink(
                .voice,
                title: L10n.string("mobile.settings.voice", defaultValue: "Voice"),
                systemImage: "mic",
                identifier: "MobileSettingsVoiceRow"
            )
            settingsPageLink(
                .notifications,
                title: L10n.string("mobile.settings.notifications", defaultValue: "Notifications"),
                systemImage: "bell",
                identifier: "MobileSettingsNotificationsRow"
            )
            settingsPageLink(
                .about,
                title: L10n.string("mobile.settings.about", defaultValue: "About"),
                systemImage: "info.circle",
                identifier: "MobileSettingsAboutRow"
            )
            settingsPageLink(
                .privacy,
                title: L10n.string("mobile.settings.privacy", defaultValue: "Privacy"),
                systemImage: "hand.raised",
                identifier: "MobileSettingsPrivacyRow"
            )
            settingsPageLink(
                .troubleshooting,
                title: L10n.string("mobile.settings.troubleshooting", defaultValue: "Troubleshooting"),
                systemImage: "wrench.and.screwdriver",
                identifier: "MobileSettingsTroubleshootingRow"
            )
        }
    }

    private func settingsPageLink(
        _ route: MobileSettingsRoute,
        title: String,
        systemImage: String,
        identifier: String
    ) -> some View {
        NavigationLink(value: route) {
            Label(title, systemImage: systemImage)
        }
        .accessibilityIdentifier(identifier)
    }

    /// Whether the Connection section has any rows to show. When this sheet is
    /// reused from the no-devices screen there is no connected Mac, no store to
    /// switch with, and no rescan action, so the section is omitted entirely.
    private var hasConnectionSection: Bool {
        !connectedHostName.isEmpty || store != nil || rescanQR != nil
    }

    /// Drives the team Picker. Reads the effective current team (`resolvedTeamID`,
    /// which falls back to the first team when nothing is explicitly selected) so
    /// the picker always shows a concrete selection, and writes the user's choice
    /// to `selectedTeamID`.
    private var teamSelection: Binding<String?> {
        Binding(
            get: { authManager.resolvedTeamID },
            set: { newValue in
                if let newValue, newValue != authManager.selectedTeamID {
                    authManager.selectedTeamID = newValue
                }
            }
        )
    }

    private var accountEmail: String {
        let email = authManager.currentUser?.primaryEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let email, !email.isEmpty { return email }
        return L10n.string("mobile.settings.notSignedIn", defaultValue: "Not signed in")
    }

    private var accountDisplayName: String {
        let name = authManager.currentUser?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        return L10n.string("mobile.settings.account", defaultValue: "Account")
    }

    #if DEBUG
    private func debugLayoutSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(debugPointValue(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1)
        }
        .accessibilityIdentifier(identifier)
    }

    private func debugPointValue(_ value: Double) -> String {
        String(
            format: L10n.string("mobile.settings.pointsFormat", defaultValue: "%lld pt"),
            Int64(value.rounded())
        )
    }
    #endif
}

private enum MobileSettingsRoute: Hashable {
    case terminal
    case browser
    case voice
    case notifications
    case about
    case privacy
    case troubleshooting
}
#endif
