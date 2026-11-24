import Foundation

/// Settings → Needs You Look: how a workspace row that waits for the person shows it, the Mac's
/// `notifications.attention.mark` (`AttentionMarkLook`, the same values). Leo 2026-11-19: "needs you"
/// as motion, a look customization off by default; the badge stays the default.
public enum AttentionMarkLook: String, CaseIterable, Identifiable, Sendable, Codable {
    /// The needs-you or unread dot in the row's gutter (the default).
    case badge
    /// No dot: the row breathes a soft halo in the dot's color until it is opened; a row that
    /// still waits once opened shows its dot again.
    case glow

    public static let `default`: AttentionMarkLook = .badge

    public var id: String { rawValue }

    /// The Mac's choice titles (`settings.choice.badge`, `settings.choice.glow`).
    public var title: String {
        switch self {
        case .badge: "Badge"
        case .glow: "Glow"
        }
    }

    /// A stored value, else the default (badge).
    public init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .default
    }
}
