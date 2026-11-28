import Foundation

/// A column docked to a viewport edge, `columns[].dock`: left or right
/// (`dock-columns-v1`), top or bottom (also `edge-docks-v1`).
public struct DockSnapshot: Sendable, Hashable, Decodable {
    public enum Edge: String, Sendable, Hashable, Decodable {
        case left, right, top, bottom

        public var isBand: Bool { self == .top || self == .bottom }
    }
    public enum Mode: String, Sendable, Hashable, Decodable { case docked, overlay }
    /// What the column is for (`dock-column-role-v1`): the agent chat column.
    public enum Role: String, Sendable, Hashable, Decodable { case agentChat = "agent_chat" }
    public var edge: Edge
    public var mode: Mode
    public var role: Role?
    /// `pinned-dock-v1`: a pinned column (the Home dock). Its first tab
    /// stays (no close, move out or reorder away), and it takes no other tab
    /// unless ``allowsTabs``. The daemon enforces it; the app hides the
    /// controls that would ask.
    public var isPinned: Bool
    /// `pinned-dock-v1`: a pinned column takes more tabs (off by default).
    public var allowsTabs: Bool

    public init(edge: Edge, mode: Mode, role: Role? = nil, isPinned: Bool = false, allowsTabs: Bool = false) {
        self.edge = edge
        self.mode = mode
        self.role = role
        self.isPinned = isPinned
        self.allowsTabs = allowsTabs
    }

    enum CodingKeys: String, CodingKey {
        case edge, mode, role
        case isPinned = "pinned"
        case allowsTabs = "allow_tabs"
    }

    /// Unknown values from a newer daemon fall back to the defaults
    /// (right, docked, no role) rather than dropping the screen.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edge = (try? c.decodeIfPresent(String.self, forKey: .edge)).flatMap { $0.flatMap(Edge.init(rawValue:)) } ?? .right
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)).flatMap { $0.flatMap(Mode.init(rawValue:)) } ?? .docked
        role = (try? c.decodeIfPresent(String.self, forKey: .role)).flatMap { $0.flatMap(Role.init(rawValue:)) }
        isPinned = (try? c.decodeIfPresent(Bool.self, forKey: .isPinned)).flatMap { $0 } ?? false
        allowsTabs = (try? c.decodeIfPresent(Bool.self, forKey: .allowsTabs)).flatMap { $0 } ?? false
    }
}
