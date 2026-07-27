#if os(iOS)
import Foundation

/// NotificationCenter observer token owned and removed on the main actor.
final class ChatKeyboardNotificationToken: @unchecked Sendable {
    // Safety: the token is created, stored, and removed by
    // ChatKeyboardTrackingViewController on the main actor. The wrapper is
    // Sendable only so the @MainActor controller can hold it under Swift 6
    // checking; it does not permit cross-actor mutation of the token.
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    func remove() {
        NotificationCenter.default.removeObserver(token)
    }
}
#endif
