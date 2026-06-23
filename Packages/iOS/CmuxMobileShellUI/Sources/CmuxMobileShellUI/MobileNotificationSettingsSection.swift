#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Settings rows for iPhone push opt-in and Mac forwarding preferences.
struct MobileNotificationSettingsSection: View {
    var store: CMUXMobileShellStore?

    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    /// Mirrors the local APNs opt-in so action rows update after async changes.
    @State private var notificationsLocallyEnabled = false
    @State private var notificationForwardingEnabled = false
    @State private var notificationMode = MobileNotificationForwardingMode.defaultMode
    @State private var hideNotificationContent = false
    @State private var notificationSettingsSyncing = false
    @State private var notificationSettingsRefreshing = false

    var body: some View {
        Section(L10n.string("mobile.settings.notifications", defaultValue: "Notifications")) {
            LabeledContent {
                Text(notificationStatusText)
                    .foregroundStyle(receivesNotifications ? .primary : .secondary)
            } label: {
                Label(
                    L10n.string("mobile.notifications.status", defaultValue: "Agent Notifications"),
                    systemImage: receivesNotifications ? "bell.badge" : "bell.slash"
                )
            }
            .accessibilityIdentifier("MobileSettingsNotificationsStatus")

            Button {
                toggleNotifications()
            } label: {
                Label(
                    receivesNotifications
                        ? L10n.string("mobile.notifications.disable", defaultValue: "Turn Off Agent Notifications")
                        : L10n.string("mobile.notifications.enable", defaultValue: "Notify Me About Agents"),
                    systemImage: receivesNotifications ? "bell.slash" : "bell"
                )
            }
            .accessibilityIdentifier("MobileSettingsNotifications")
            .disabled(notificationSettingsSyncing)

            if notificationsLocallyEnabled && !receivesNotifications {
                Button {
                    disableNotifications()
                } label: {
                    Label(
                        L10n.string("mobile.notifications.disable", defaultValue: "Turn Off Agent Notifications"),
                        systemImage: "bell.slash"
                    )
                }
                .accessibilityIdentifier("MobileSettingsNotificationsLocalOptOut")
                .disabled(notificationSettingsSyncing)
            }

            if store?.supportsNotificationSettings == false {
                Text(L10n.string("mobile.notifications.unsupportedHint", defaultValue: "Update cmux on this Mac to manage phone notifications from iPhone."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if notificationsLocallyEnabled {
                Picker(selection: notificationModeBinding) {
                    Text(L10n.string("mobile.notifications.mode.always", defaultValue: "Always"))
                        .tag(MobileNotificationForwardingMode.always)
                    Text(L10n.string(
                        "mobile.notifications.mode.onlyWhenAway",
                        defaultValue: "Only When Away from Mac"
                    ))
                    .tag(MobileNotificationForwardingMode.onlyWhenAway)
                } label: {
                    Text(L10n.string("mobile.notifications.mode", defaultValue: "When to Notify"))
                }
                .accessibilityIdentifier("MobileSettingsNotificationsMode")
                .disabled(notificationSettingsControlsDisabled)

                Toggle(isOn: hideNotificationContentBinding) {
                    Text(L10n.string(
                        "mobile.notifications.hideContent",
                        defaultValue: "Hide Notification Content"
                    ))
                }
                .accessibilityIdentifier("MobileSettingsNotificationsHideContent")
                .disabled(notificationSettingsControlsDisabled)

                Text(notificationModeExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.string(
                    "mobile.notifications.disabledHint",
                    defaultValue: "Turn this on to receive completed agent and workspace notifications on this iPhone."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            loadNotificationPreferences(pushCoordinator.notificationPreferences)
            refreshNotificationPreferencesFromMac()
        }
    }

    private var notificationStatusText: String {
        if notificationSettingsSyncing || notificationSettingsRefreshing {
            return L10n.string("mobile.notifications.status.syncing", defaultValue: "Syncing")
        }
        if receivesNotifications {
            return L10n.string("mobile.notifications.status.on", defaultValue: "On")
        }
        return L10n.string("mobile.notifications.status.off", defaultValue: "Off")
    }

    private var receivesNotifications: Bool {
        notificationsLocallyEnabled && notificationForwardingEnabled
    }

    private var notificationSettingsControlsDisabled: Bool {
        notificationSettingsSyncing || notificationSettingsRefreshing
    }

    private var notificationModeExplanation: String {
        switch notificationMode {
        case .always:
            return L10n.string(
                "mobile.notifications.mode.always.hint",
                defaultValue: "Your Mac forwards notifications to this iPhone even when it was recently used."
            )
        case .onlyWhenAway:
            return L10n.string(
                "mobile.notifications.mode.onlyWhenAway.hint",
                defaultValue: "Phone notifications can be suppressed while the Mac is awake, unlocked, or recently used."
            )
        }
    }

    private var notificationModeBinding: Binding<MobileNotificationForwardingMode> {
        Binding {
            notificationMode
        } set: { mode in
            guard !notificationSettingsControlsDisabled, notificationMode != mode else { return }
            notificationMode = mode
            updateNotificationMode(mode)
        }
    }

    private var hideNotificationContentBinding: Binding<Bool> {
        Binding {
            hideNotificationContent
        } set: { hidesContent in
            guard !notificationSettingsControlsDisabled, hideNotificationContent != hidesContent else { return }
            hideNotificationContent = hidesContent
            updateNotificationHideContent(hidesContent)
        }
    }

    private func loadNotificationPreferences(_ preferences: MobileNotificationPreferences) {
        notificationsLocallyEnabled = preferences.isEnabled
        notificationForwardingEnabled = preferences.isForwardingEnabled
        notificationMode = preferences.forwardingMode
        hideNotificationContent = preferences.hidesContent
    }

    private func refreshNotificationPreferencesFromMac() {
        guard !notificationSettingsRefreshing else { return }
        notificationSettingsRefreshing = true
        Task { @MainActor in
            defer { notificationSettingsRefreshing = false }
            let preferences = await pushCoordinator.reconcileNotificationPreferencesWithMac()
            loadNotificationPreferences(preferences)
        }
    }

    private func toggleNotifications() {
        guard !notificationSettingsSyncing else { return }
        let shouldDisable = receivesNotifications
        let shouldRefreshBeforeEnable = notificationSettingsRefreshing
        notificationSettingsSyncing = true
        Task { @MainActor in
            defer { notificationSettingsSyncing = false }
            if shouldDisable {
                await pushCoordinator.disable()
                loadNotificationPreferences(pushCoordinator.notificationPreferences)
            } else {
                if shouldRefreshBeforeEnable {
                    let preferences = await pushCoordinator.reconcileNotificationPreferencesWithMac()
                    loadNotificationPreferences(preferences)
                }
                let enabled = await pushCoordinator.enable()
                notificationsLocallyEnabled = enabled
                loadNotificationPreferences(pushCoordinator.notificationPreferences)
            }
        }
    }

    private func disableNotifications() {
        guard !notificationSettingsSyncing else { return }
        notificationSettingsSyncing = true
        Task { @MainActor in
            defer { notificationSettingsSyncing = false }
            await pushCoordinator.disable()
            loadNotificationPreferences(pushCoordinator.notificationPreferences)
        }
    }

    private func updateNotificationMode(_ mode: MobileNotificationForwardingMode) {
        guard notificationsLocallyEnabled,
              store?.supportsNotificationSettings != false,
              !notificationSettingsControlsDisabled else { return }
        notificationSettingsSyncing = true
        Task { @MainActor in
            defer { notificationSettingsSyncing = false }
            let preferences = await pushCoordinator.setForwardingMode(mode)
            loadNotificationPreferences(preferences)
        }
    }

    private func updateNotificationHideContent(_ hidesContent: Bool) {
        guard notificationsLocallyEnabled,
              store?.supportsNotificationSettings != false,
              !notificationSettingsControlsDisabled else { return }
        notificationSettingsSyncing = true
        Task { @MainActor in
            defer { notificationSettingsSyncing = false }
            let preferences = await pushCoordinator.setHidesContent(hidesContent)
            loadNotificationPreferences(preferences)
        }
    }
}
#endif
