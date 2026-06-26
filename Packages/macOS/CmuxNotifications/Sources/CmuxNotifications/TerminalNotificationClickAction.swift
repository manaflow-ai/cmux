import Foundation

/// The action performed when the user clicks a delivered terminal notification.
///
/// Pure value type encoding itself to/from a notification's `userInfo`
/// dictionary so it survives the round trip through `UNNotificationContent`. It
/// reaches into no live state, so it lives in the notifications package.
public enum TerminalNotificationClickAction: Codable, Hashable, Sendable {
    /// Reveal the file at `path` in Finder (selecting it, or opening its
    /// containing directory).
    case revealInFinder(path: String)

    private static let kindUserInfoKey = "cmuxClickAction"
    private static let revealInFinderPathUserInfoKey = "cmuxRevealInFinderPath"
    private static let revealInFinderKind = "revealInFinder"

    /// The notification `userInfo` representation of this action, using the
    /// stable wire keys so a delivered notification can reconstruct it.
    public var userInfo: [String: String] {
        switch self {
        case .revealInFinder(let path):
            return [
                Self.kindUserInfoKey: Self.revealInFinderKind,
                Self.revealInFinderPathUserInfoKey: path,
            ]
        }
    }

    /// Reconstructs a click action from a notification's `userInfo`, returning
    /// `nil` when the dictionary carries no recognized action.
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
