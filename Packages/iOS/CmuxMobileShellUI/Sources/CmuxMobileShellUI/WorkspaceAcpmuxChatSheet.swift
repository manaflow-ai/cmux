import CmuxAgentChatUI
import CmuxMobileShell
import SwiftUI

/// Owns the conversation store for one sheet presentation. Keeping this
/// lifetime above ``ChatConversationView`` prevents a SwiftUI body refresh from
/// recreating the RPC event stream or losing the keyboard draft.
struct WorkspaceAcpmuxChatSheet: View {
    let source: AcpmuxMobileEventSource
    let workspaceID: String
    @State private var conversationStore: ChatConversationStore

    init(source: AcpmuxMobileEventSource, workspaceID: String) {
        self.source = source
        self.workspaceID = workspaceID
        _conversationStore = State(
            initialValue: ChatConversationStore(source: source, workspaceID: workspaceID)
        )
    }

    var body: some View {
        ChatConversationView(store: conversationStore)
            .presentationBackground(.regularMaterial)
    }
}
