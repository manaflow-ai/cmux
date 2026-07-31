import Foundation

/// Wraps the opaque observer returned by `NotificationCenter.addObserver` so it
/// can cross task boundaries despite Objective-C not modeling Sendable.
///
/// Safety: the token is an immutable reference, this final class exposes no
/// mutable shared state, and `remove()` only passes that token back to
/// NotificationCenter's thread-safe observer-removal API. Callers own the
/// lifecycle and must call `remove()` when their stream terminates.
final class NotificationObserverToken: @unchecked Sendable {
    private let tokens: [NSObjectProtocol]
    private let notificationCenter: NotificationCenter

    init(_ token: NSObjectProtocol, notificationCenter: NotificationCenter = .default) {
        self.tokens = [token]
        self.notificationCenter = notificationCenter
    }

    init(_ tokens: [NSObjectProtocol], notificationCenter: NotificationCenter = .default) {
        self.tokens = tokens
        self.notificationCenter = notificationCenter
    }

    func remove() {
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
    }
}
