public import CoreGraphics

/// Leading icon of a tab.
public enum TabIcon: Hashable, Sendable {
    case none
    /// An SF Symbol name, tinted to the tab's text color.
    case symbol(String)
    /// A full-color image such as a favicon. Drawn as is.
    case image(TabImage)
    /// An agent's brand mark (a CmuxAgentBrands brand id such as "claude"),
    /// tinted to the tab's text color like a symbol.
    case agentMark(String)
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
