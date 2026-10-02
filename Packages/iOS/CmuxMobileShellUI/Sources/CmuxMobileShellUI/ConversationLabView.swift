#if os(iOS) && DEBUG
import CmuxConversationCore
import CmuxConversationUI
import SwiftUI
import UIKit

/// DEBUG lab: the Messages-style conversation GUI against the conversation
/// simulator (`services/conversation-sim`), so the transcript can be
/// exercised under real latency, failures, and deep history.
struct ConversationLabView: UIViewControllerRepresentable {
    let endpoint: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let backend = ConversationSimBackend(endpoint: endpoint)
        let store = ConversationStore(backend: backend)
        let isGroup = endpoint.query?.contains("conversation=direct") != true
        let controller = ConversationViewController(
            store: store,
            options: ConversationPresentationOptions(unreadCount: isGroup ? 349 : 0, trailingSymbol: "video")
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.setNavigationBarHidden(true, animated: false)
        return navigation
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
#endif
