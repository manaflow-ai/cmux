import Foundation

/// Wraps the opaque observer returned by `NotificationCenter.addObserver` so it
/// can cross task boundaries despite Objective-C not modeling Sendable.
///
/// Safety: the token is an immutable reference, this final class exposes no
/// mutable shared state, and `remove()` only passes that token back to
/// NotificationCenter's thread-safe observer-removal API. Callers own the
/// lifecycle and must call `remove()` when their stream terminates.
final class NotificationObserverToken: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    func remove() {
        NotificationCenter.default.removeObserver(token)
    }
}
