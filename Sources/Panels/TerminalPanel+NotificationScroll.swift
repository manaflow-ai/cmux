import Foundation

@MainActor
extension TerminalPanel {
    var notificationScrollPosition: TerminalNotificationScrollPosition? {
        hostedView.notificationScrollPosition
    }

    @discardableResult
    func restoreNotificationScrollPosition(_ position: TerminalNotificationScrollPosition?) -> Bool {
        guard !isAgentHibernated else { return false }
        return hostedView.restoreNotificationScrollPosition(position)
    }
}
