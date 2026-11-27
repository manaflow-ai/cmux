internal import Foundation

/// Owns Objective-C notification tokens for the socket server's lifetime.
///
/// Safety: `install(_:)` runs once during the main-actor server initializer,
/// before the bag is shared. After installation the token array is immutable;
/// `deinit` only returns those opaque tokens to NotificationCenter's
/// thread-safe removal API.
final class SocketAuthorizationObserverBag: @unchecked Sendable {
    let notificationCenter: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []
    private var changeTask: Task<Void, Never>?

    init(notificationCenter: NotificationCenter) {
        self.notificationCenter = notificationCenter
    }

    func install(
        _ tokens: [any NSObjectProtocol],
        changeTask: Task<Void, Never>?
    ) {
        precondition(self.tokens.isEmpty)
        self.tokens = tokens
        self.changeTask = changeTask
    }

    deinit {
        changeTask?.cancel()
        tokens.forEach(notificationCenter.removeObserver)
    }
}
