import CmuxRemoteSession
import Foundation

/// A tmux window within a mirrored session, assembled from the control-mode
/// stream (`%window-add` / `%layout-change`) by ``RemoteTmuxControlConnection``.
///
/// Maps to a cmux tab; its ``layout`` tree (parsed by
/// ``RemoteTmuxRawLayoutParser``) maps to the tab's pane splits.
struct RemoteTmuxWindow: Sendable, Equatable, Codable {
    /// tmux's numeric window id (the `@N` without the leading `@`), stable for
    /// the server's lifetime.
    let id: Int
    /// The tmux window name (`#{window_name}`), shown as the mirrored tab's
    /// title. Empty when tmux has not reported a name yet.
    let name: String
    /// Window width in terminal cells.
    let width: Int
    /// Window height in terminal cells.
    let height: Int
    /// The pane-layout tree for this window.
    let layout: RemoteTmuxLayoutNode

    init(id: Int, name: String = "", width: Int, height: Int, layout: RemoteTmuxLayoutNode) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.layout = layout
    }

    /// All pane ids in this window, depth-first left-to-right.
    var paneIDsInOrder: [Int] { layout.paneIDsInOrder }
}
