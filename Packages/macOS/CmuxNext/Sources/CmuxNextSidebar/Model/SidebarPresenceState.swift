import Foundation

/// The daemon-wide presence summary shown by the footer status icon.
public nonisolated struct SidebarPresenceState: Equatable, Sendable {
    public var active: Int
    public var working: Int
    public var connected: Bool

    public init(active: Int = 0, working: Int = 0, connected: Bool = false) {
        self.active = active
        self.working = working
        self.connected = connected
    }
}
