import CmuxHomeCore
import SwiftUI

/// A native Chief pane with its own collapsible conversation list.
struct ChiefPanelView: NSViewRepresentable {
    @ObservedObject var panel: ChiefPanel
    let isFocused: Bool
    let isVisibleInUI: Bool

    func makeNSView(context: Context) -> ChiefPanelHostView {
        let view = ChiefPanelHostView(conversation: panel.conversationID, isHome: panel.isHome)
        view.onOpenConversation = { [weak panel] id in
            if panel?.conversationID != id { panel?.conversationID = id }
        }
        view.updatePresentation(visible: isVisibleInUI, focused: isFocused, generation: panel.focusRequestGeneration)
        return view
    }

    func updateNSView(_ view: ChiefPanelHostView, context: Context) {
        view.updatePresentation(visible: isVisibleInUI, focused: isFocused, generation: panel.focusRequestGeneration)
        view.show(panel.conversationID)
    }

    static func dismantleNSView(_ view: ChiefPanelHostView, coordinator: ()) {
        view.stop()
    }
}
