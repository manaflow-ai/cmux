#if os(iOS)
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI

/// The mobile app's settings page. Surfaces the signed-in account (so the user
/// can confirm which cmux account this device uses — the account must match the
/// Mac it pairs with), plus terminal shortcuts, agent notifications, and the
/// paired Mac. Presented as a sheet from the workspace list.
struct MobileSettingsView: View {
    /// Shared with `UserDefaultsAnalyticsConsentProvider`; keep the string stable
    /// so Settings controls the same gate used by analytics and crash reporting.
    private static let sendAnonymousTelemetryKey = "sendAnonymousTelemetry"

    @Environment(AuthCoordinator.self) private var authManager
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    @Environment(MobileDisplaySettings.self) private var displaySettings
    let connectedHostName: String
    let rescanQR: (() -> Void)?
    let signOut: (() -> Void)?
    /// The shell store, used to drive the multi-Mac switcher. `nil` in previews,
    /// where the "Switch Mac" entry is hidden.
    var store: CMUXMobileShellStore?
    @AppStorage(MobileSettingsView.sendAnonymousTelemetryKey) private var sendAnonymousTelemetry = false

    @Environment(\.dismiss) private var dismiss
    @State private var showingShortcuts = false
    /// Mirrors ``MobilePushCoordinator/isEnabled`` so the toggle's label/icon
    /// update after the async enable/disable. The coordinator exposes
    /// `isEnabled` as a non-observable `UserDefaults` read, so reading it
    /// directly in `body` would not re-render when it flips.
    @State private var notificationsEnabled = false
    @State private var showingHostPicker = false
    @State private var showingOnboarding = false
    @State private var showingSetupHelp = false
    #if DEBUG
    @State private var showingChatDemo = false
    @State private var showingTerminalDemo = false
    #endif

    var body: some View {
        @Bindable var displaySettings = displaySettings
        return NavigationStack {
            Form {
                MobileSettingsAccountSection(signOut: signOut)

                // Stack team switcher. Only shown when the user belongs to more than
                // one team. Rendered as an INLINE picker — each team is a row with a
                // checkmark on the current one — so every team is visible at a glance
                // and one tap switches (clearer than a menu/navigation push for a
                // small set). Selecting a team writes `selectedTeamID`, which the root
                // view observes to re-scope the team-bound surfaces (paired Macs,
                // presence, backup) to that team without dropping the live terminal.
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

                // Hidden entirely when there is nothing to show (no connected
                // Mac, no store to switch with, no rescan), so the no-devices
                // screen's reuse of this sheet does not render an empty header.
                if hasConnectionSection {
                    Section(L10n.string("mobile.settings.connection", defaultValue: "Connection")) {
                        if !connectedHostName.isEmpty {
                            LabeledContent(
                                L10n.string("mobile.settings.mac", defaultValue: "Computer"),
                                value: connectedHostName
                            )
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
                }

                Section(L10n.string("mobile.settings.terminal", defaultValue: "Terminal")) {
                    Toggle(isOn: $displaySettings.showAltScreenNotice) {
                        Text(L10n.string(
                            "mobile.settings.altScreenNotice",
                            defaultValue: "Full-Screen Sizing Notice"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsAltScreenNoticeToggle")

                    Button {
                        showingShortcuts = true
                    } label: {
                        Label(
                            L10n.string("mobile.workspaces.terminalShortcuts", defaultValue: "Terminal Shortcuts"),
                            systemImage: "keyboard"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsTerminalShortcuts")
                }

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

                Section(L10n.string("mobile.settings.display", defaultValue: "Display")) {
                    Toggle(isOn: $displaySettings.wrapWorkspaceTitles) {
                        Text(L10n.string("mobile.settings.wrapTitles", defaultValue: "Wrap Workspace Titles"))
                    }
                    .accessibilityIdentifier("MobileSettingsWrapTitles")

                    Picker(selection: $displaySettings.workspacePreviewLineCount) {
                        Text(L10n.string("mobile.settings.previewLines.one", defaultValue: "1 Line"))
                            .tag(1)
                        Text(L10n.string("mobile.settings.previewLines.two", defaultValue: "2 Lines"))
                            .tag(2)
                    } label: {
                        Text(L10n.string("mobile.settings.previewLines", defaultValue: "Preview Lines"))
                    }
                    .accessibilityIdentifier("MobileSettingsPreviewLines")
                }

                Section(L10n.string("mobile.settings.notifications", defaultValue: "Notifications")) {
                    Button {
                        Task {
                            if notificationsEnabled {
                                await pushCoordinator.disable()
                                notificationsEnabled = false
                            } else {
                                notificationsEnabled = await pushCoordinator.enable()
                            }
                        }
                    } label: {
                        Label(
                            notificationsEnabled
                                ? L10n.string("mobile.notifications.disable", defaultValue: "Turn Off Agent Notifications")
                                : L10n.string("mobile.notifications.enable", defaultValue: "Notify Me About Agents"),
                            systemImage: notificationsEnabled ? "bell.slash" : "bell"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsNotifications")
                }

                Section {
                    Toggle(isOn: $sendAnonymousTelemetry) {
                        Text(L10n.string(
                            Self.crashReportingEnabled
                                ? "mobile.settings.telemetry"
                                : "mobile.settings.telemetryAnalyticsOnly",
                            defaultValue: Self.crashReportingEnabled
                                ? "Share Analytics and Crash Reports"
                                : "Share Anonymous Analytics"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsTelemetryToggle")
                } header: {
                    Text(L10n.string("mobile.settings.privacy", defaultValue: "Privacy"))
                } footer: {
                    Text(L10n.string(
                        Self.crashReportingEnabled
                            ? "mobile.settings.telemetryFooter"
                            : "mobile.settings.telemetryAnalyticsOnlyFooter",
                        defaultValue: Self.crashReportingEnabled
                            ? "When off, cmux does not send iPhone or iPad product analytics or crash reports."
                            : "When off, cmux does not send iPhone or iPad product analytics."
                    ))
                }

                MobileSettingsLegalSupportSection()

                Section(L10n.string("mobile.settings.about", defaultValue: "About")) {
                    LabeledContent {
                        Text(AppVersionInfo.current().displayString)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: {
                        Label(
                            L10n.string("mobile.settings.version", defaultValue: "Version"),
                            systemImage: "info.circle"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsVersionRow")
                }
            }
            .onAppear { notificationsEnabled = pushCoordinator.isEnabled }
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
            .sheet(isPresented: $showingShortcuts) {
                TerminalShortcutsSettingsView()
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
            .sheet(isPresented: $showingOnboarding) {
                // Re-entry from Settings: walk the explainer again. `onComplete`
                // only dismisses; it never touches the persisted seen flag. No
                // current blocker is highlighted, since reaching Settings means the
                // user got past every setup gate.
                OnboardingFlowView(
                    onComplete: { showingOnboarding = false },
                    setupHelpHighlight: setupHelpHighlight
                )
            }
            .sheet(isPresented: $showingSetupHelp) {
                // Re-enterable setup help as a plain reference: every pre-pairing
                // gate with its concrete next step. Settings is reached only from
                // the connected workspace list, so there is no current blocker to
                // mark "You are here".
                SetupHelpView(highlight: setupHelpHighlight) { showingSetupHelp = false }
            }
        }
        .accessibilityIdentifier("MobileSettingsView")
    }

    private static var crashReportingEnabled: Bool {
        switch Bundle.main.object(forInfoDictionaryKey: "CMUXCrashReportingEnabled") {
        case let enabled as Bool:
            enabled
        case let enabled as String:
            enabled.caseInsensitiveCompare("NO") != .orderedSame
        default:
            true
        }
    }

    /// Which setup gate to mark as the user's current blocker. Settings is reached
    /// only from the connected workspace list, so the user has cleared every gate
    /// and there is no "You are here" step; the help is a plain reference. `nil`
    /// keeps that honest instead of mislabeling a connected Mac as unreachable.
    private var setupHelpHighlight: MobileSetupGuidanceState? {
        nil
    }

    /// Whether the Connection section has any rows to show. When this sheet is
    /// reused from the no-devices screen there is no connected Mac, no store to
    /// switch with, and no rescan action, so the section is omitted entirely.
    private var hasConnectionSection: Bool {
        !connectedHostName.isEmpty || store != nil || rescanQR != nil
    }

    /// Drives the team Picker. Reads the EFFECTIVE current team (`resolvedTeamID`,
    /// which falls back to the first team when nothing is explicitly selected) so
    /// the picker always shows a concrete selection, and writes the user's choice
    /// to `selectedTeamID` (persisted; observed by the root for the lazy re-scope).
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
#endif
