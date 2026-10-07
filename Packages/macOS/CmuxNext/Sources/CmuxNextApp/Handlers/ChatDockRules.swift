import CmuxNextBridge
import CmuxNextLayout

/// What the chat dock refuses (lawrence-call-1006 D).
enum ChatDockRules {
    static func refusesSplit(of pane: LayoutPaneID, columns: [LayoutColumn]) -> Bool { false }

    static func refusesTab(isChat: Bool, into pane: LayoutPaneID, columns: [LayoutColumn]) -> Bool { false }
}
