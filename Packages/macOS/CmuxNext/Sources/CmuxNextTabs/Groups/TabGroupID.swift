import Foundation

/// Stable identity of one tab group. The App uses the daemon's group id.
public nonisolated struct TabGroupID: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

nonisolated extension TabID {
    private static let chipPrefix = "__cmux.tabs.group-chip__/"

    /// Layout identity of a group's chip. Chips share the tab slot machinery
    /// (springs, layout slots) under a reserved id that can never collide
    /// with a daemon tab id.
    static func groupChip(_ group: TabGroupID) -> TabID {
        TabID(chipPrefix + group.rawValue)
    }

    /// The id names a group chip, not a tab.
    var isGroupChip: Bool { rawValue.hasPrefix(Self.chipPrefix) }

    /// The group whose chip this id names, or nil for a real tab.
    var chipGroupID: TabGroupID? {
        guard rawValue.hasPrefix(Self.chipPrefix) else { return nil }
        return TabGroupID(String(rawValue.dropFirst(Self.chipPrefix.count)))
    }
}
