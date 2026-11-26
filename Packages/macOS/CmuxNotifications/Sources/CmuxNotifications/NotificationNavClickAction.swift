import Foundation

/// A notification click action the coordinator can dispatch without knowing
/// how it is performed. The single case mirrors the app-target
/// `TerminalNotificationClickAction`; the coordinator forwards it to
/// ``NotificationClickRouting`` and never performs the side effect itself.
public enum NotificationNavClickAction: Sendable, Equatable {
    /// Reveal the file at `path` in Finder (selecting it, or opening its
    /// containing directory). Mirrors the app-target reveal-in-Finder action.
    case revealInFinder(path: String)

    private static let kindUserInfoKey = "cmuxClickAction"
    private static let revealInFinderPathUserInfoKey = "cmuxRevealInFinderPath"
    private static let revealInFinderKind = "revealInFinder"

    /// Creates a click action from terminal notification `userInfo`, preserving
    /// the app-target wire keys used by `TerminalNotificationClickAction`.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let kind = userInfo[Self.kindUserInfoKey] as? String else { return nil }
        switch kind {
        case Self.revealInFinderKind:
            guard let path = userInfo[Self.revealInFinderPathUserInfoKey] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self = .revealInFinder(path: path)
        default:
            return nil
        }
    }
}
