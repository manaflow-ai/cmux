import Foundation

/// Owns a NotificationCenter token for the AppKit system-color notification.
@MainActor
final class NotificationCenterSystemColorsObservation: SystemColorsObservation {
    private let token: NSObjectProtocol

    init(token: NSObjectProtocol) {
        self.token = token
    }

    func invalidate() {
        NotificationCenter.default.removeObserver(token)
    }
}
