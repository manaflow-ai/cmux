import Foundation

/// Foreign (other-process) windows sit above cmux's own window, so anything
/// cmux floats over a pane (command palette, popovers, notifications, drag
/// previews) would render underneath them. cmux UI that floats begins a yield;
/// foreign-window hosts hide while any yield is active and restore after.
@MainActor
final class ForeignWindowYieldCoordinator {
    static let shared = ForeignWindowYieldCoordinator()

    /// Posted on the main thread whenever `isYielding` changes.
    static let didChangeNotification = Notification.Name("cmux.foreignWindowYield.didChange")

    struct Token: Hashable {
        fileprivate let id = UUID()
        let reason: String
    }

    private var active: Set<Token> = []

    var isYielding: Bool { !active.isEmpty }

    /// Starts a yield. Balance every call with `endYield(_:)`.
    func beginYield(reason: String) -> Token {
        let token = Token(reason: reason)
        let wasYielding = isYielding
        active.insert(token)
        if !wasYielding { postChange() }
        return token
    }

    func endYield(_ token: Token) {
        guard active.remove(token) != nil, !isYielding else { return }
        postChange()
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
