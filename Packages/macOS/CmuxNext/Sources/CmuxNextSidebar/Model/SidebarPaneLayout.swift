import Foundation

/// A workspace's split layout on its shown screen, as the hover card's shaped preview draws it: the split tree and
/// each pane's tabs in order (Leo 2026-11-22: "i have this layout. so. the preview should be able to depict that.").
public nonisolated struct SidebarPaneLayout: Sendable, Equatable {
    /// The split tree, in the daemon's own shape.
    public indirect enum Node: Sendable, Equatable, Encodable {
        case leaf(String)
        /// `right`: `b` beside `a`; else `b` under `a`.
        case split(right: Bool, ratio: Double, a: Node, b: Node)
        case stack(panes: [String], expanded: String)

        private enum Keys: String, CodingKey { case type, pane, dir, ratio, a, b, panes, expanded }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .leaf(pane):
                try c.encode("leaf", forKey: .type)
                try c.encode(pane, forKey: .pane)
            case let .split(right, ratio, a, b):
                try c.encode("split", forKey: .type)
                try c.encode(right ? "right" : "down", forKey: .dir)
                try c.encode(ratio, forKey: .ratio)
                try c.encode(a, forKey: .a)
                try c.encode(b, forKey: .b)
            case let .stack(panes, expanded):
                try c.encode("stack", forKey: .type)
                try c.encode(panes, forKey: .panes)
                try c.encode(expanded, forKey: .expanded)
            }
        }
    }

    /// One pane: its tabs in order and the one it shows.
    public struct Pane: Sendable, Equatable {
        public var id: String
        public var tabs: [TabID]
        public var active: Int

        public init(id: String, tabs: [TabID], active: Int) {
            self.id = id
            self.tabs = tabs
            self.active = active
        }
    }

    public var root: Node
    public var panes: [Pane]
    /// The pane focused last; its tile draws a focus edge.
    public var focused: String?

    public init(root: Node, panes: [Pane], focused: String? = nil) {
        self.root = root
        self.panes = panes
        self.focused = focused
    }

    /// More than one pane: a layout worth drawing as a shape. One pane is the tab list.
    public var isSplit: Bool { panes.count > 1 }
}

/// The split layout of workspace `id`'s shown screen, read when its hover card opens; nil when the app has none.
public typealias SidebarPaneLayoutSource = @MainActor (_ workspace: WorkspaceID) -> SidebarPaneLayout?
