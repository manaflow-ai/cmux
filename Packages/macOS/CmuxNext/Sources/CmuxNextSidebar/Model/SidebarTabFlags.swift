/// A tab's page facts the workspace hover card marks (one byte per tab).
public nonisolated struct SidebarTabFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The page plays sound.
    public static let playing = SidebarTabFlags(rawValue: 1 << 0)
    /// The page is muted.
    public static let muted = SidebarTabFlags(rawValue: 1 << 1)
    /// The page is hibernated: its renderer is gone until the tab is shown again.
    public static let hibernated = SidebarTabFlags(rawValue: 1 << 2)
}
