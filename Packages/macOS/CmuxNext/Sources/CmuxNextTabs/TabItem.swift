public import CoreGraphics
import Foundation

/// Stable identity of one tab. The App layer uses the daemon's tab id.
public struct TabID: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

/// Leading icon of a tab.
public enum TabIcon: Hashable, Sendable {
    case none
    /// An SF Symbol name, tinted to the tab's text color.
    case symbol(String)
    /// A full-color image such as a favicon. Drawn as is.
    case image(TabImage)
}

/// A full-color tab image (favicon). Compared by identity so that updating
/// a tab with the same image object does not redraw it.
public final class TabImage: Hashable, @unchecked Sendable {
    // CGImage is immutable once created, which makes the unchecked Sendable sound.
    public let cgImage: CGImage

    public init(_ cgImage: CGImage) {
        self.cgImage = cgImage
    }

    public static func == (lhs: TabImage, rhs: TabImage) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Agent or process status shown as a small colored dot on the icon.
/// A status dot takes priority over the neutral unread dot.
public enum TabStatus: Hashable, Sendable {
    case none
    case needsInput
    case success
    case failure
}

/// One tab as the strip displays it. The App fills these from daemon state.
public struct TabItem: Identifiable, Hashable, Sendable {
    public var id: TabID
    public var title: String
    /// Working directory or URL. Shown in the hover card.
    public var subtitle: String?
    public var icon: TabIcon
    public var isPinned: Bool
    /// Neutral notification dot (new output, unread notification).
    public var isUnread: Bool
    /// Replaces the icon with a spinner (process running, page loading).
    public var isBusy: Bool
    public var status: TabStatus

    public init(
        id: TabID,
        title: String,
        subtitle: String? = nil,
        icon: TabIcon = .symbol("terminal"),
        isPinned: Bool = false,
        isUnread: Bool = false,
        isBusy: Bool = false,
        status: TabStatus = .none
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.isPinned = isPinned
        self.isUnread = isUnread
        self.isBusy = isBusy
        self.status = status
    }
}
