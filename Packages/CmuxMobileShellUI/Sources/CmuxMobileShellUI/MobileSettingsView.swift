#if os(iOS)
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileWorkspace
import SwiftUI
import UIKit

/// The mobile app's settings page. Surfaces the signed-in account (so the user
/// can confirm which cmux account this device uses — the account must match the
/// Mac it pairs with), plus terminal shortcuts, agent notifications, and the
/// paired Mac. Presented as a sheet from the workspace list.
struct MobileSettingsView: View {
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    @Environment(MobileDisplaySettings.self) private var displaySettings
    let connectedHostName: String
    let rescanQR: (() -> Void)?
    let signOut: (() -> Void)?
    /// The shell store, used to drive the multi-Mac switcher. `nil` in previews,
    /// where the "Switch Mac" entry is hidden.
    var store: CMUXMobileShellStore?

    @Environment(\.dismiss) private var dismiss
    @State private var showingShortcuts = false
    /// Mirrors ``MobilePushCoordinator/isEnabled`` so the toggle's label/icon
    /// update after the async enable/disable. The coordinator exposes
    /// `isEnabled` as a non-observable `UserDefaults` read, so reading it
    /// directly in `body` would not re-render when it flips.
    @State private var notificationsEnabled = false
    /// Live OS authorization, so the section can route to iOS Settings when the
    /// in-app toggle cannot grant notifications the system has denied.
    @State private var notificationAuthorization: MobilePushCoordinator.NotificationAuthorizationStatus = .notDetermined
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
                        defaultValue: "This device must be signed in to the same cmux account as the Mac you pair with."
                    ))
                }

                // Hidden entirely when there is nothing to show (no connected
                // Mac, no store to switch with, no rescan), so the no-devices
                // screen's reuse of this sheet does not render an empty header.
                if hasConnectionSection {
                    Section(L10n.string("mobile.settings.connection", defaultValue: "Connection")) {
                        if !connectedHostName.isEmpty {
                            LabeledContent(
                                L10n.string("mobile.settings.mac", defaultValue: "Mac"),
                                value: connectedHostName
                            )
                        }
                        if store != nil {
                            Button {
                                showingHostPicker = true
                            } label: {
                                Label(
                                    L10n.string("mobile.settings.switchMac", defaultValue: "Switch Mac"),
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
                            L10n.string("mobile.settings.setUpYourMac", defaultValue: "Set up your Mac"),
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
                Section("Developer") {
                    Button {
                        showingChatDemo = true
                    } label: {
                        Label("Agent Chat Demo", systemImage: "bubble.left.and.bubble.right")
                    }
                    .accessibilityIdentifier("MobileSettingsAgentChatDemo")
                    Button {
                        showingTerminalDemo = true
                    } label: {
                        Label("Terminal Log Demo", systemImage: "terminal")
                    }
                    .accessibilityIdentifier("MobileSettingsTerminalLogDemo")
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

                Section {
                    Button {
                        Task { await toggleNotifications() }
                    } label: {
                        Label(
                            notificationsEnabled
                                ? L10n.string("mobile.notifications.disable", defaultValue: "Turn Off Agent Notifications")
                                : L10n.string("mobile.notifications.enable", defaultValue: "Notify Me About Agents"),
                            systemImage: notificationsEnabled ? "bell.slash" : "bell"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsNotifications")

                    // The in-app opt-in cannot override an iOS Settings denial;
                    // surface that explicitly with a one-tap route to Settings
                    // instead of a tap that silently does nothing.
                    if notificationAuthorization == .denied {
                        Button {
                            openSystemNotificationSettings()
                        } label: {
                            Label(
                                L10n.string(
                                    "mobile.notifications.openSettings",
                                    defaultValue: "Open iOS Settings"
                                ),
                                systemImage: "gear"
                            )
                        }
                        .accessibilityIdentifier("MobileSettingsNotificationsOpenSettings")
                    }
                } header: {
                    Text(L10n.string("mobile.settings.notifications", defaultValue: "Notifications"))
                } footer: {
                    Text(notificationsFooter)
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
            .onAppear { notificationsEnabled = pushCoordinator.isEnabled }
            .task { notificationAuthorization = await pushCoordinator.authorizationStatus() }
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

    /// Drive the opt-in/opt-out and reconcile both the in-app flag and the live
    /// OS authorization, so a denied prompt flips the section into its
    /// "Open iOS Settings" state instead of silently staying off.
    private func toggleNotifications() async {
        if notificationsEnabled {
            await pushCoordinator.disable()
            notificationsEnabled = false
        } else {
            switch await pushCoordinator.enable() {
            case .granted:
                notificationsEnabled = true
            case .declined, .blockedBySystemSettings:
                notificationsEnabled = false
            }
        }
        notificationAuthorization = await pushCoordinator.authorizationStatus()
    }

    /// Open this app's iOS Settings page so the user can re-enable notifications
    /// the system has denied (the in-app toggle cannot).
    private func openSystemNotificationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Footer copy that names the two requirements a phone-only opt-in does not
    /// satisfy: the OS permission, and the paired Mac's forwarding toggle. The
    /// most common "notifications don't work" cause is a fully opted-in phone
    /// whose Mac never enabled forwarding, which the phone alone cannot reveal.
    private var notificationsFooter: String {
        switch notificationAuthorization {
        case .denied:
            return L10n.string(
                "mobile.notifications.footer.denied",
                defaultValue: "Notifications are turned off for cmux in iOS Settings. Open Settings to allow them, then turn on \"Forward notifications to my iPhone\" on your Mac in cmux Settings > Notifications."
            )
        case .notDetermined, .authorized:
            return L10n.string(
                "mobile.notifications.footer.setup",
                defaultValue: "Also turn on \"Forward notifications to my iPhone\" on your Mac in cmux Settings > Notifications. Agent notifications are sent only while you are away from the Mac unless you choose Always."
            )
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
