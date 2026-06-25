public import Foundation

/// A notification click action the coordinator can dispatch without knowing how
/// it is performed. This is the single, canonical click-action value model for
/// the notification domain: it is stored on ``TerminalNotification``, persisted
/// in the session snapshot, encoded into / decoded from `UNNotification`
/// `userInfo`, and forwarded to ``NotificationClickRouting`` so the coordinator
/// never performs the side effect itself.
///
/// It used to be duplicated by an app-target `TerminalNotificationClickAction`
/// with identical cases and identical wire keys; that twin was retired and every
/// call site now speaks this type directly. The synthesized `Codable` and the
/// `userInfo` keys are byte-identical to that retired enum, so persisted session
/// snapshots and delivered-notification `userInfo` stay compatible.
public enum NotificationNavClickAction: Codable, Hashable, Sendable {
    /// Reveal the file at `path` in Finder (selecting it, or opening its
    /// containing directory). Mirrors the app-target reveal-in-Finder action.
    case revealInFinder(path: String)

    private static let kindUserInfoKey = "cmuxClickAction"
    private static let revealInFinderPathUserInfoKey = "cmuxRevealInFinderPath"
    private static let revealInFinderKind = "revealInFinder"

    /// The `UNNotification` `userInfo` payload that encodes this action so the
    /// delivery delegate can reconstruct it via ``init(userInfo:)``. Keys are the
    /// stable wire keys (`cmuxClickAction` / `cmuxRevealInFinderPath`).
    public var userInfo: [String: String] {
        switch self {
        case .revealInFinder(let path):
            return [
                Self.kindUserInfoKey: Self.revealInFinderKind,
                Self.revealInFinderPathUserInfoKey: path,
            ]
        }
    }

    /// Creates a click action from terminal notification `userInfo`, preserving
    /// the stable wire keys used by the delivered `UNNotification`.
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
