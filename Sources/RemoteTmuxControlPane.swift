import Bonsplit
import Foundation

/// A read-only control-plane projection of one pane rendered inside a
/// multi-pane remote-tmux window mirror.
@MainActor
struct RemoteTmuxControlPane {
    let tmuxPaneID: Int
    let paneID: PaneID
    let panel: TerminalPanel
    let title: String
    let isFocused: Bool
}
