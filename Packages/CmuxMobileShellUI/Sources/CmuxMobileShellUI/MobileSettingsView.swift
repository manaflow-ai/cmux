#if os(iOS)
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// The mobile app's settings page. Surfaces the signed-in account (so the user
/// can confirm which cmux account this device uses — the account must match the
/// Mac it pairs with), plus terminal shortcuts, agent notifications, and the
/// paired Mac. Presented as a sheet from the workspace list.
struct MobileSettingsView: View {
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
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
    @State private var showingHostPicker = false

    var body: some View {
        NavigationStack {
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
            .sheet(isPresented: $showingHostPicker) {
                if let store {
                    MobileHostPickerView(store: store)
                }
            }
        }
        .accessibilityIdentifier("MobileSettingsView")
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
