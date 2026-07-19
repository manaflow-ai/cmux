import Bonsplit
import Foundation

/// A read-only control-plane projection of one pane in a mirrored tmux session.
@MainActor
struct RemoteTmuxControlPane {
    let tmuxPaneID: Int
    let paneID: PaneID
    let panel: TerminalPanel
    let title: String
    let isFocused: Bool
}
