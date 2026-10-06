public import CmuxNextDesign
import Foundation

/// Stable identifier of a profile (the daemon's profile id).
public nonisolated struct ProfileKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

/// One dot in the sidebar's profile bar (plans/cmux-next/data-model.md 7):
/// a named set of workspaces the window can switch to.
public nonisolated struct SidebarProfile: Hashable, Sendable, Identifiable {
    public var id: ProfileKey
    public var name: String
    /// Tint of the dot or icon; nil draws the plain foreground dot.
    public var color: GroupColor?
    /// An SF Symbol name or one emoji shown instead of the dot.
    public var icon: String?

    public init(id: ProfileKey, name: String, color: GroupColor? = nil, icon: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
    }

    /// Whether `icon` is an emoji (drawn as text) rather than a symbol name.
    public var iconIsEmoji: Bool {
        if case .emoji? = IconValue(wire: icon) { true } else { false }
    }
}
