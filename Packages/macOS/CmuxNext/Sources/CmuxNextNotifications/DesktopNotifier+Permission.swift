package import AppKit
import CmuxNextCompat
import CmuxNextDesign
package import CmuxNextSettings

/// macOS notification permission in the app (cmux#55600): read at launch and each time cmux comes
/// forward (asked once while not yet determined), a denial told once in the app with Open System
/// Settings, and Settings > Notifications' Allow. Sounds never depend on it: a banner macOS will not
/// sound has its `"default"` sound played by the app (``playsDefaultSound``).
extension DesktopNotifier {
    /// The toast id of the one-time denied notice.
    package static let deniedNoticeID = "notifications-denied"

    /// Reads the permission now (asking while not yet determined); the app reads it again on each
    /// activation (back from System Settings: AppDelegate's activation pass). A denial shows the
    /// one-time notice in `window()`, once there is one.
    /// `sounds`: the app's sound gate, whose player then plays `"default"` while banners cannot (at `volume()`).
    /// `asks`: false in a showcase capture, which never reads or asks.
    package func followPermission(sounds: NotificationSoundGate, volume: @escaping @MainActor () -> Double, asks: Bool,
                                  window: @escaping @MainActor () -> NSWindow?) -> Task<Void, Never> {
        (sounds.player as? NotificationSoundPlayer)?.bannersCarrySound = { [weak self] in self?.permissionState.bannersCarrySound ?? true }
        playsDefaultSound = { [weak sounds] in sounds?.player.play("default", volume: volume(), banner: false) }
        guard asks else {
            readsPermission = false // a showcase never reads the host Mac's permission, at launch or on activation
            return Task {}
        }
        onDenied = { [weak self] in
            // No window yet: the notice stays unclaimed, so the next read (an activation) shows it.
            guard let self, let window = window(), self.deniedNotice.claim(for: self.authorization) else { return }
            Self.showDeniedNotice(in: window)
        }
        return Task { [weak self] in // inherits the main actor
            // The launch read can stall (`notificationSettings()` takes seconds on a busy launch): while
            // nothing has landed, more reads start alongside it, each on its own, so one stuck read blocks none.
            Task { [weak self] in await self?.refreshPermission() }
            for _ in 0..<(self?.launchRereads.count ?? 0) {
                try? await Task.sleep(for: self?.launchRereads.delay ?? .zero)
                guard self?.authorization == "unknown" else { return }
                Task { [weak self] in await self?.refreshPermission(asking: false) }
            }
        }
    }

    /// Settings > Notifications' button (the person's click): the macOS prompt while not yet asked,
    /// else System Settings > Notifications at cmux, the only place a denial is undone.
    package func allowFromSettings() async throws {
        let center = try permission()
        var permission = await center.status()
        if permission.authorization == "not_determined" {
            permission = try await center.request()
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
