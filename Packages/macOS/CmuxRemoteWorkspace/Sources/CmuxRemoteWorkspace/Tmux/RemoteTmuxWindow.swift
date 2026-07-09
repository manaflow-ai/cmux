import Foundation

/// A tmux window within a mirrored session, assembled from the control-mode
/// stream (`%window-add` / `%layout-change`) by ``RemoteTmuxControlConnection``.
///
/// Maps to a cmux tab; its ``layout`` tree (parsed by
/// ``RemoteTmuxRawLayoutParser``) maps to the tab's pane splits.
public struct RemoteTmuxWindow: Sendable, Equatable, Codable {
    /// tmux's numeric window id (the `@N` without the leading `@`), stable for
    /// the server's lifetime.
    public let id: Int
    /// The tmux window name (`#{window_name}`), shown as the mirrored tab's
    /// title. Empty when tmux has not reported a name yet.
    public let name: String
    /// Window width in terminal cells.
    public let width: Int
    /// Window height in terminal cells.
    public let height: Int
    /// The pane-layout tree for this window — tmux's BASE layout (field 2 of
    /// `%layout-change`), which stays the full tree even while a pane is
    /// zoomed. Panel lifecycle and client sizing key off this tree.
    public let layout: RemoteTmuxLayoutNode
    /// tmux's VISIBLE layout (field 3 of `%layout-change`): the single-pane
    /// tree while zoomed, identical to ``layout`` otherwise. Rendering
    /// imposes THIS tree. `nil` only when tmux never reported one.
    public let visibleLayout: RemoteTmuxLayoutNode?
    /// Whether the window is zoomed RIGHT NOW, derived per event from the
    /// flags field (`Z` present). Never latched: tmux auto-unzooms on its
    /// own (e.g. killing a hidden pane while zoomed emits a single
    /// already-unzoomed layout change), so a stored flag goes stale.
    public let zoomed: Bool

    public init(
        id: Int,
        name: String = "",
        width: Int,
        height: Int,
        layout: RemoteTmuxLayoutNode,
        visibleLayout: RemoteTmuxLayoutNode? = nil,
        zoomed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.layout = layout
        self.visibleLayout = visibleLayout
        self.zoomed = zoomed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        layout = try container.decode(RemoteTmuxLayoutNode.self, forKey: .layout)
        visibleLayout = try container.decodeIfPresent(RemoteTmuxLayoutNode.self, forKey: .visibleLayout)
        zoomed = try container.decodeIfPresent(Bool.self, forKey: .zoomed) ?? false
    }

    /// All pane ids in this window, depth-first left-to-right.
    public var paneIDsInOrder: [Int] { layout.paneIDsInOrder }
}
