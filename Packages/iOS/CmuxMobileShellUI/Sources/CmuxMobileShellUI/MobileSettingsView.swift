#if os(iOS)
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI

struct MobileSettingsView: View {
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    @Environment(MobileDisplaySettings.self) private var displaySettings
    @Environment(\.analytics) private var analytics
    let connectedHostName: String
    let rescanQR: (() -> Void)?
    let signOut: (() -> Void)?
    var store: CMUXMobileShellStore?
    let telemetryConsentStore: MobileTelemetryConsentStore
    let accountDeletionClient: MobileAccountDeletionClient?

    @Environment(\.dismiss) private var dismiss
    @State private var showingShortcuts = false
    /// Mirrors ``MobilePushCoordinator/isEnabled`` so the toggle's label/icon
    /// update after the async enable/disable. The coordinator exposes
    /// `isEnabled` as a non-observable `UserDefaults` read, so reading it
    /// directly in `body` would not re-render when it flips.
    @State private var notificationsEnabled = false
    @State private var productAnalyticsEnabled: Bool
    @State private var showingHostPicker = false
    @State private var showingOnboarding = false
    @State private var showingSetupHelp = false
    @State private var showingDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    @State private var accountDeletionErrorMessage: String?
    #if DEBUG
    @State private var showingChatDemo = false
    @State private var showingTerminalDemo = false
    #endif

    init(
        connectedHostName: String,
        rescanQR: (() -> Void)?,
        signOut: (() -> Void)?,
        store: CMUXMobileShellStore?,
        telemetryConsentStore: MobileTelemetryConsentStore,
        accountDeletionClient: MobileAccountDeletionClient?
    ) {
        self.connectedHostName = connectedHostName
        self.rescanQR = rescanQR
        self.signOut = signOut
        self.store = store
        self.telemetryConsentStore = telemetryConsentStore
        self.accountDeletionClient = accountDeletionClient
        _productAnalyticsEnabled = State(initialValue: telemetryConsentStore.isEnabled)
    }

    var body: some View {
        @Bindable var displaySettings = displaySettings
        return NavigationStack {
            Form {
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
                        .disabled(isDeletingAccount)
                    }

                    if authManager.currentUser != nil, accountDeletionClient != nil {
                        Button(role: .destructive) {
                            showingDeleteAccountConfirmation = true
                        } label: {
                            Label(
                                L10n.string("mobile.settings.deleteAccount", defaultValue: "Delete Account"),
                                systemImage: "trash"
                            )
                        }
                        .disabled(isDeletingAccount)
                        .accessibilityIdentifier("MobileSettingsDeleteAccount")
                    }
                } header: {
                    Text(L10n.string("mobile.settings.account", defaultValue: "Account"))
                } footer: {
                    Text(L10n.string(
                        "mobile.settings.accountFooter",
                        defaultValue: "This device must be signed in to the same cmux account as the computer you pair with."
                    ))
                }

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
                    Toggle(isOn: productAnalyticsBinding) {
                        Text(L10n.string(
                            "mobile.settings.shareProductAnalytics",
                            defaultValue: "Share Product Analytics"
                        ))
                    }
                    .accessibilityIdentifier("MobileSettingsProductAnalytics")

                    Link(destination: Self.privacyPolicyURL) {
                        Label(
                            L10n.string("mobile.settings.privacyPolicy", defaultValue: "Privacy Policy"),
                            systemImage: "hand.raised"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsPrivacyPolicy")
                } header: {
                    Text(L10n.string("mobile.settings.privacy", defaultValue: "Privacy"))
                } footer: {
                    Text(L10n.string(
                        "mobile.settings.privacyFooter",
                        defaultValue: "Product analytics include app launches, pairing results, feature usage, and counts. They never include terminal text, prompts, pasted content, images, or files."
                    ))
                }

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
            .onAppear {
                notificationsEnabled = pushCoordinator.isEnabled
                productAnalyticsEnabled = telemetryConsentStore.isEnabled
            }
            .navigationTitle(L10n.string("mobile.workspaces.settings", defaultValue: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.settings.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .disabled(isDeletingAccount)
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
                OnboardingFlowView(
                    onComplete: { showingOnboarding = false },
                    setupHelpHighlight: setupHelpHighlight
                )
            }
            .sheet(isPresented: $showingSetupHelp) {
                SetupHelpView(highlight: setupHelpHighlight) { showingSetupHelp = false }
            }
            .mobileSettingsAccountDeletionAlerts(
                showingConfirmation: $showingDeleteAccountConfirmation,
                errorMessage: $accountDeletionErrorMessage,
                deleteAccount: deleteAccount
            )
        }
        .interactiveDismissDisabled(isDeletingAccount)
        .accessibilityIdentifier("MobileSettingsView")
    }

    private var setupHelpHighlight: MobileSetupGuidanceState? {
        nil
    }

    private static let privacyPolicyURL = URL(string: "https://cmux.com/privacy-policy")!
    private var productAnalyticsBinding: Binding<Bool> {
        Binding(
            get: { productAnalyticsEnabled },
            set: { newValue in
                productAnalyticsEnabled = newValue
                telemetryConsentStore.setEnabled(newValue)
                analytics.setTelemetryConsentEnabled(newValue)
            }
        )
    }

    private func deleteAccount() {
        guard let accountDeletionClient else { return }
        isDeletingAccount = true
        Task {
            do {
                try await accountDeletionClient.deleteAccount()
                await MainActor.run {
                    isDeletingAccount = false
                    signOut?()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isDeletingAccount = false
                    accountDeletionErrorMessage = accountDeletionFailureMessage(for: error)
                }
            }
        }
    }

    private func accountDeletionFailureMessage(for error: Error) -> String {
        guard let deletionError = error as? MobileAccountDeletionClient.DeletionError else {
            return L10n.string(
                "mobile.settings.deleteAccountFailedMessage",
                defaultValue: "Check your connection and try again. If this keeps failing, contact founders@manaflow.com."
            )
        }

        switch deletionError {
        case .missingRefreshToken:
            return L10n.string(
                "mobile.settings.deleteAccountFailedSignedOutMessage",
                defaultValue: "Sign in again, then try deleting your account. If this keeps failing, contact founders@manaflow.com."
            )
        case .rejected(let statusCode) where statusCode == 401 || statusCode == 403:
            return L10n.string(
                "mobile.settings.deleteAccountFailedSignedOutMessage",
                defaultValue: "Sign in again, then try deleting your account. If this keeps failing, contact founders@manaflow.com."
            )
        case .rejected:
            return L10n.string(
                "mobile.settings.deleteAccountFailedRejectedMessage",
                defaultValue: "The server rejected the deletion request. Try again later or contact founders@manaflow.com."
            )
        case .invalidURL, .invalidResponse:
            return L10n.string(
                "mobile.settings.deleteAccountFailedUnexpectedResponseMessage",
                defaultValue: "cmux received an unexpected account deletion response. Try again later or contact founders@manaflow.com."
            )
        }
    }

    private var hasConnectionSection: Bool {
        !connectedHostName.isEmpty || store != nil || rescanQR != nil
    }

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

}
#endif
