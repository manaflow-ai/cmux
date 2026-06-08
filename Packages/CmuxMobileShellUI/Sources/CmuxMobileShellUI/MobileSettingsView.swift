#if os(iOS)
import CmuxAuthRuntime
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileTerminal
import SwiftUI

/// The mobile app's settings page. Surfaces the signed-in account (so the user
/// can confirm which cmux account this device uses — the account must match the
/// Mac it pairs with), plus terminal shortcuts, agent notifications, and the
/// paired Mac. Presented as a sheet from the workspace list.
struct MobileSettingsView: View {
    @Environment(AuthCoordinator.self) private var authManager
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    @Environment(MobileDisplaySettings.self) private var displaySettings
    @Environment(MobileTerminalZoomPreference.self) private var terminalZoomPreference
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

                Section {
                    Button {
                        showingShortcuts = true
                    } label: {
                        Label(
                            L10n.string("mobile.workspaces.terminalShortcuts", defaultValue: "Terminal Shortcuts"),
                            systemImage: "keyboard"
                        )
                    }
                    .accessibilityIdentifier("MobileSettingsTerminalShortcuts")

                    terminalFontSizeControl

                    Button {
                        terminalZoomPreference.clear()
                    } label: {
                        Label(
                            L10n.string("mobile.settings.terminalFontSizeReset", defaultValue: "Reset to Default"),
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                    .disabled(!terminalZoomPreference.hasCustomFontSize)
                    .accessibilityIdentifier("MobileSettingsTerminalFontSizeReset")
                } header: {
                    Text(L10n.string("mobile.settings.terminal", defaultValue: "Terminal"))
                } footer: {
                    Text(L10n.string(
                        "mobile.settings.terminalFontSizeFooter",
                        defaultValue: "Sets the terminal's base text size on this device. The font family follows the Mac you pair with."
                    ))
                }

                Section(L10n.string("mobile.settings.display", defaultValue: "Display")) {
                    Toggle(isOn: $displaySettings.wrapWorkspaceTitles) {
                        Text(L10n.string("mobile.settings.wrapTitles", defaultValue: "Wrap Workspace Titles"))
                    }
                    .accessibilityIdentifier("MobileSettingsWrapTitles")
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
            .sheet(isPresented: $showingHostPicker) {
                if let store {
                    MobileHostPickerView(store: store)
                }
            }
        }
        .accessibilityIdentifier("MobileSettingsView")
    }

    /// Stepper that nudges the terminal's base font size by one point, clamped
    /// to the supported zoom range. Writes the shared
    /// ``MobileTerminalZoomPreference``, so the change persists and applies live
    /// to the open terminal surface (no rebuild, no timer).
    private var terminalFontSizeControl: some View {
        let size = terminalZoomPreference.effectiveFontSize
        return Stepper {
            LabeledContent {
                Text(verbatim: "\(Int(size.rounded())) pt")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("MobileSettingsTerminalFontSizeValue")
            } label: {
                Label(
                    L10n.string("mobile.settings.terminalFontSize", defaultValue: "Font Size"),
                    systemImage: "textformat.size"
                )
            }
        } onIncrement: {
            terminalZoomPreference.step(by: 1)
        } onDecrement: {
            terminalZoomPreference.step(by: -1)
        }
        .accessibilityIdentifier("MobileSettingsTerminalFontSize")
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
