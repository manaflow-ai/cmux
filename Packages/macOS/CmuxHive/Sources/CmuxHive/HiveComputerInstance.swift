public import CMUXMobileCore
public import Foundation

/// One running (or recently seen) cmux app instance on a computer, keyed by
/// its build tag, as merged from the registry and the live presence map.
public struct HiveComputerInstance: Equatable, Sendable, Identifiable {
    /// The instance's build tag (`"stable"`, a dev tag, or `"default"`).
    public var tag: String
    /// Attach routes this instance advertises, in priority order.
    public var routes: [CmxAttachRoute]
    /// When the registry or presence service last saw this instance.
    public var lastSeenAt: Date
    /// Whether the presence service currently reports this instance online.
    public var isOnline: Bool

    /// The tag is unique per computer, so it doubles as the row id.
    public var id: String { tag }

    /// Creates an instance row.
    public init(tag: String, routes: [CmxAttachRoute], lastSeenAt: Date, isOnline: Bool) {
        self.tag = tag
        self.routes = routes
        self.lastSeenAt = lastSeenAt
        self.isOnline = isOnline
    }
}
