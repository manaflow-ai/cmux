import Foundation

// Tab drag commits (`tab-drag-v1`, plans/cmux-next/REWRITE.md "Tab drag"):
// every drop outcome is ONE atomic daemon command. Each takes an optional
// client `transaction` that the daemon echoes in the moved tab's
// `tab-changed` delta, so the App applies the move optimistically at drop
// time and reconciles when `DaemonStore` reports the echo. Moves that stay on
// one screen and keep their source pane record a layout-undo entry.

/// Result of a tab move. Fields vary by command; absent ones are nil.
public struct TabMoveResult: Decodable, Sendable, Equatable {
    public var surface: SurfaceID?
    public var pane: PaneID?
    public var screen: ScreenID?
    public var workspace: WorkspaceHandle?
    public var key: WorkspaceKey?
    public var index: Int?
    public var group: WorkspaceGroupID?
    /// `move-tab` only.
    public var moved: Bool?
    /// True when `undo-layout` can move the tab back.
    public var undoable: Bool

    enum CodingKeys: String, CodingKey {
        case surface, pane, screen, workspace, key, index, group, moved, undoable
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        surface = try c.decodeIfPresent(SurfaceID.self, forKey: .surface)
        pane = try c.decodeIfPresent(PaneID.self, forKey: .pane)
        screen = try c.decodeIfPresent(ScreenID.self, forKey: .screen)
        workspace = try c.decodeIfPresent(WorkspaceHandle.self, forKey: .workspace)
        key = try c.decodeIfPresent(WorkspaceKey.self, forKey: .key)
        index = try c.decodeIfPresent(Int.self, forKey: .index)
        group = try c.decodeIfPresent(WorkspaceGroupID.self, forKey: .group)
        moved = try c.decodeIfPresent(Bool.self, forKey: .moved)
        undoable = try c.decodeIfPresent(Bool.self, forKey: .undoable) ?? false
    }
}

/// Edge drop zone of a pane.
public enum PaneEdge: String, Sendable, Hashable, Codable {
    case left, right, top, bottom
}
