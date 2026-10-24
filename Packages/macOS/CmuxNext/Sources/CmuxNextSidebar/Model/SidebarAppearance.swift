public import CmuxNextDesign
public import CoreGraphics
import Foundation

/// Workspace icon: an SF Symbol (tinted with the workspace color, if any),
/// one emoji (on a chip of the workspace color, if any), a color swatch
/// when the workspace has a color and no icon, or the page icon of a
/// browser workspace's front tab when it has neither.
public nonisolated enum WorkspaceIcon: Hashable, Sendable {
    case symbol(String, tint: GroupColor? = nil)
    case swatch(GroupColor)
    /// One emoji, drawn as text, on a chip of `chip` when set.
    case emoji(String, chip: GroupColor? = nil)
    /// The front tab's favicon, drawn as is.
    case favicon(SidebarFavicon)

    /// This icon without the workspace's color (`sidebar.showColors` off): a swatch is no icon, a
    /// symbol is untinted and an emoji has no chip; a favicon is the page's own.
    public var uncolored: WorkspaceIcon? {
        switch self {
        case .swatch: nil
        case let .symbol(name, _): .symbol(name, tint: nil)
        case let .emoji(text, _): .emoji(text, chip: nil)
        case .favicon: self
        }
    }

    /// The workspace record's `icon` string (workspace-metadata-v1) through
    /// the one icon rule (``IconValue``); nil when it is not an emoji or a
    /// symbol name. Image and SVG assets draw as a placeholder symbol while
    /// their image loads (the mapping's `iconAsset` draws them after).
    public static func parse(_ value: String, color: GroupColor? = nil) -> WorkspaceIcon? {
        switch IconValue(wire: value) {
        case .emoji(let text)?: .emoji(text, chip: color)
        case .symbol(let name)?: .symbol(name, tint: color)
        case .image?, .svg?: .symbol("photo", tint: color)
        case nil: nil
        }
    }
}

/// A favicon image. Compared by image identity, so a row given the same
/// cached icon again does not redraw it.
// crash-allow: CGImage is immutable once created, so sharing it across actors is sound.
public nonisolated struct SidebarFavicon: Hashable, @unchecked Sendable {
    public let image: CGImage

    public init(_ image: CGImage) {
        self.image = image
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.image === rhs.image }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(image)) }
}

/// How the sidebar occupies the window: fully shown at the user's width,
/// or fully hidden (zero width, content reaches the window edge). There is
/// no intermediate state.
public nonisolated enum SidebarPresentation: Hashable, Sendable {
    case shown
    case hidden
}
