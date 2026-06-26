import Foundation

enum DesktopNotificationPermissionAction: Equatable, Sendable {
    case requestAuthorization
    case openSystemSettings
}

enum DesktopNotificationPermissionStatusLabel: Equatable, Sendable {
    case unknown
    case notRequested
    case allowed
    case denied
    case deliverQuietly
    case temporary
}

enum DesktopNotificationPermissionSubtitle: Equatable, Sendable {
    case notDetermined
    case allowed
    case denied
}

struct DesktopNotificationPermissionPresentation: Equatable, Sendable {
    var statusLabel: DesktopNotificationPermissionStatusLabel
    var subtitle: DesktopNotificationPermissionSubtitle
    var primaryAction: DesktopNotificationPermissionAction
    var sendTestEnabled: Bool

    static func make(
        for state: DesktopNotificationAuthorizationState
    ) -> DesktopNotificationPermissionPresentation {
        _ = state
        return DesktopNotificationPermissionPresentation(
            statusLabel: .unknown,
            subtitle: .notDetermined,
            primaryAction: .requestAuthorization,
            sendTestEnabled: true
        )
    }
}
