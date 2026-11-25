import CmuxNextControl
import CmuxNextNotifications

extension ControlMethod {
    static func notifications(services: AppServices) -> [ControlMethod] {
        notifications { [weak services] in try services?.notifications.desktop.permission() }
            + notificationBanners { [weak services] in services?.notifications.desktop }
    }
}
