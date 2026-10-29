public import CmuxTheme

/// A workspace group's color (cx-25az): one of the group palette tokens, a
/// custom color a person picked, or no color at all. The wire form is the
/// token's raw value, `#RRGGBB`, or `none`, the shapes the daemon stores for
/// a group color.
public nonisolated enum GroupTint: Hashable, Sendable {
    case palette(GroupColor)
    case custom(ThemeRGB)
    /// No color (Lawrence 2026-10-22: "need to be able to remove all workspace colors"): the
    /// header draws in the sidebar's own colors, with no dot, band, wash or members' line.
    case none

    /// The wire form of ``none``. A group with no stored color is not this: it draws a picked
    /// palette color (`GroupColor.unset(id:)`).
    public static let noneWire = "none"

    /// A token, `#RRGGBB` or `none`; nil for anything else.
    public init?(wire: String) {
        if wire == Self.noneWire {
            self = .none
        } else if let token = GroupColor(rawValue: wire) {
            self = .palette(token)
        } else if wire.hasPrefix("#"), let rgb = ThemeRGB(cssHex: wire) {
            self = .custom(rgb.withAlpha(1))
        } else {
            return nil
        }
    }

    public var wire: String {
        switch self {
        case let .palette(token): token.rawValue
        case let .custom(rgb): rgb.withAlpha(1).description
        case .none: Self.noneWire
        }
    }

    /// Whether this is no color.
    public var isNone: Bool { self == .none }

    /// The palette token, grey for a custom color or no color.
    public var token: GroupColor {
        if case let .palette(token) = self { token } else { .grey }
    }
}
