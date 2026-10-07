import CmuxNextBridge
import CmuxNextLayout

/// The agent chat's pane chrome (lawrence-call-1006 D): the chat dock shows
/// no tab strip by default.
enum ChatDockChrome {
    static func hidesStrip(pane: LayoutPaneID, columns: [LayoutColumn], tabCount: Int, isLoneChat: Bool) -> Bool {
        false
    }
}
