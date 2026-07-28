import Foundation

/// Selection contract for a remote tmux split. Every mutation caller must state
/// whether tmux may select the created pane; background automation uses
/// `preserveActivePane`, which maps to `split-window -d`.
enum RemoteTmuxSplitFocusIntent: Sendable, Equatable {
    case preserveActivePane
    case focusCreatedPane

    func command(vertical: Bool, windowID: Int, paneID: Int) -> String {
        let detached = self == .preserveActivePane ? " -d" : ""
        return "split-window\(detached) \(vertical ? "-v" : "-h") -t @\(windowID).%\(paneID)"
    }
}
