import CmuxNextControl
import CmuxNextNotifications

extension NotificationsControl {
    static func methods(services: AppServices) -> [ControlMethod] {
        methods { [weak services] in try services?.notifications.desktop.permission() }
    }
}
