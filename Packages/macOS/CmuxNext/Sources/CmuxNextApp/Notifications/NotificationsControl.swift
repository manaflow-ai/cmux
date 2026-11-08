import CmuxNextControl
import CmuxNextNotifications
import CmuxNextSettings
import Foundation

/// `notifications.status`: whether macOS lets cmux show notifications, read without prompting
/// (`UNUserNotificationCenter.notificationSettings`): `{authorization, alert, alert_style, sound,
/// badge, bundle_id}`, `authorization` one of not_determined, denied, authorized, provisional,
/// unknown; `alert_style` one of none, banner, alert, unknown (`alert` can stay true with the
/// style None: only `alert_style` says whether a banner shows).
///
/// `notifications.request`: asks for it (`requestAuthorization`, the macOS prompt, shown only
/// while it is not_determined: the person's one click) and answers the status after.
/// `cmux setup notifications` reads one and asks with the other. A launch that never uses the
/// system center (an automation launch, a GUI job, a host that is not the app bundle) answers
/// `unavailable`. Not in the remote relay allowlist: an ssh session has no business prompting.
enum NotificationsControl {
    /// The macOS prompt waits for the person; the system bounds it, this only ends a lost one.
    static let requestDeadline: Duration = .seconds(600)

    static func methods(services: AppServices) -> [ControlMethod] {
        methods { [weak services] in try services?.notifications.desktop.permission() }
    }

    /// The methods over `center`, made on the main actor for each call (nil: the app is closing).
    /// On the main actor because `DesktopNotifier` is main-actor-only; the settings read itself runs
    /// off the main actor in the follow-up.
    static func methods(center make: @escaping @MainActor @Sendable () throws -> (any NotificationPermissionCenter)?) -> [ControlMethod] {
        [
            .mainActor("notifications.status") { _ in
                guard let center = try make() else { return .value(.null) }
                return .followUp { await center.status().json }
            },
            .mainActor("notifications.request") { _ in
                guard let center = try make() else { return .value(.null) }
                return .followUp { try await center.request().json }
            }.withDeadline(.fixed(requestDeadline)),
        ]
    }
}
