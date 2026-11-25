package import AppKit
import CmuxNextCompat
import CmuxNextDesign
package import CmuxNextSettings
import CmuxNextWakeups

/// macOS notification permission in the app (cmux#55600). cmux never asks on its own: the macOS prompt shows only
/// when the person turns notifications on (Settings > Notifications' button, or `notifications.desktop` leaving
/// Never). Until macOS allows them, banners and notification sounds stay off, previews included; turning them on
/// while macOS blocks them tells the person, with Open System Settings (the only place a denial is undone).
extension DesktopNotifier {
    /// The toast id of the denied notice.
    package static let deniedNoticeID = "notifications-denied"

    /// Reads the permission now (never asking); the app reads it again on each activation (back from System
    /// Settings: AppDelegate's activation pass). `sounds`: the app's sound gate, whose player plays only while
    /// macOS allows cmux notifications. `asks`: false in a showcase capture, which never reads. `window()`: where
    /// the denied notice shows.
    package func followPermission(sounds: NotificationSoundGate, asks: Bool, window: @escaping @MainActor () -> NSWindow?) -> Task<Void, Never> {
        (sounds.player as? NotificationSoundPlayer)?.soundsAllowed = { [weak self] in self?.permissionState.allowsSounds ?? true }
        guard asks else {
            readsPermission = false // a showcase never reads the host Mac's permission, at launch or on activation
            return Task {}
        }
        onDenied = { if let window = window() { Self.showDeniedNotice(in: window) } }
        // The launch read can stall (`notificationSettings()` takes seconds on a busy launch): while
        // nothing has landed, more reads start on a deadline, each on its own, so one stuck read blocks none.
        rereadWhileUnknown(left: launchRereads.count)
        return Task { [weak self] in await self?.refreshPermission() } // inherits the main actor
    }

    private func rereadWhileUnknown(left: Int) {
        guard left > 0 else { return }
        launchRereadTimer.schedule(after: launchRereads.delay) { @MainActor [weak self] in
            guard let self, self.authorization == "unknown" else { return }
            Task { await self.refreshPermission() }
            self.rereadWhileUnknown(left: left - 1)
        }
    }

    /// The person turned notifications on (`notifications.desktop` left Never): not yet asked, the macOS prompt;
    /// blocked (already, or by their answer), the denied notice.
    package func turnOn() async {
        guard readsPermission, let center = permissionCenterOverride ?? (try? permission()) else { return }
        var permission = await center.status()
        if permission.authorization == "not_determined", let answered = try? await center.request() { permission = answered }
        applyPermission(permission)
        if permission.isDenied { onDenied?() }
    }

    /// `notifications.desktop` changed: leaving Never is the person turning notifications on (``turnOn()``).
    package func desktopModeChanged(from old: DesktopNotificationMode, to new: DesktopNotificationMode) {
        guard old == .never, new != .never else { return }
        Task { await turnOn() } // inherits the main actor; the prompt waits for the person, the settings never do
    }

    /// Settings > Notifications' button (the person's click): the macOS prompt while not yet asked (a denial
    /// answered there shows the denied notice), else System Settings > Notifications at cmux.
    package func allowFromSettings() async throws {
        let center = try permissionCenterOverride ?? permission()
        var permission = await center.status()
        if permission.authorization == "not_determined" {
            permission = try await center.request()
            if permission.isDenied { onDenied?() }
        } else if let url = permission.settingsURL {
            NSWorkspace.shared.openInForeground(url)
        }
        applyPermission(permission) // as of now: newer than any read still in flight
    }

    /// "macOS is blocking cmux notifications" with Open System Settings, in `window`.
    static func showDeniedNotice(in window: NSWindow) {
        let toast = CmuxToast(id: deniedNoticeID, message: NotificationPermissionStrings.deniedNotice,
                              action: CmuxToast.Action(title: NotificationPermissionStrings.openSettings),
                              duration: .seconds(12), tone: .warning)
        let handle = CmuxToastCenter.shared.show(toast, in: window)
        let url = NotificationPermission(authorization: "denied", alert: false, alertStyle: "none", sound: false, badge: false,
                                         bundleID: Bundle.main.bundleIdentifier).settingsURL
        handle.onAction = { if let url { NSWorkspace.shared.openInForeground(url) } }
    }
}
