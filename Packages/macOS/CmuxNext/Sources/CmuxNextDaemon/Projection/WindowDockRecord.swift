import Foundation

/// One docked workspace of a window's frame (`WindowRecord.docks`, plans/cmux-next/docked-workspace-DESIGN.md): an
/// ordinary workspace held at one edge of the window while the stage follows the sidebar. Opaque to the daemon, like
/// the rest of the record; cmux-tui stores the same shape for its client view.
public struct WindowDockRecord: Codable, Sendable, Hashable {
    /// `left`, `right`, `top` or `bottom`. A client skips an edge it does not know.
    public var edge: String
    /// The docked workspace, one the window lists.
    public var workspaceKey: WorkspaceKey
    /// `docked` (takes space from the stage) or `floating` (floats over the stage's edge).
    public var mode: String
    /// Width (left, right) or height (top, bottom) as permille of the frame, 100...900; each client clamps it to
    /// its own maximum share.
    public var extentPermille: Int
    /// Toggled off: the dock keeps its workspace but takes no space and draws nothing.
    public var hidden: Bool
    /// The Home Chief pane's no-tab-bar mode for this dock: a pane showing one tab draws no tab bar.
    /// Absent (an older build's record) is off.
    public var hidesTabBar: Bool

    public init(edge: String, workspaceKey: WorkspaceKey, mode: String, extentPermille: Int, hidden: Bool, hidesTabBar: Bool = false) {
        self.edge = edge
        self.workspaceKey = workspaceKey
        self.mode = mode
        self.extentPermille = extentPermille
        self.hidden = hidden
        self.hidesTabBar = hidesTabBar
    }

    enum CodingKeys: String, CodingKey {
        case edge, mode, hidden
        case workspaceKey = "workspace_key"
        case extentPermille = "extent_permille"
        case hidesTabBar = "hide_tab_bar"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(edge, forKey: .edge)
        try c.encode(workspaceKey, forKey: .workspaceKey)
        try c.encode(mode, forKey: .mode)
        try c.encode(extentPermille, forKey: .extentPermille)
        try c.encode(hidden, forKey: .hidden)
        // Written only when on, so a record without the mode reads as before.
        if hidesTabBar { try c.encode(true, forKey: .hidesTabBar) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edge = try c.decode(String.self, forKey: .edge)
        workspaceKey = try c.decode(WorkspaceKey.self, forKey: .workspaceKey)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "docked"
        extentPermille = try c.decodeIfPresent(Int.self, forKey: .extentPermille) ?? 300
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        hidesTabBar = try c.decodeIfPresent(Bool.self, forKey: .hidesTabBar) ?? false
    }
}
