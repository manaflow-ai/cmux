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

    /// The other hosted conversation stays live so the back button counts its
    /// unread messages, as Messages counts every other conversation.
    final class Coordinator {
        var others: [ConversationStore] = []
        var badge: ConversationUnreadBadge?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UINavigationController {
        let backend = ConversationSimBackend(endpoint: endpoint)
        let store = ConversationStore(backend: backend)
        let isGroup = endpoint.query?.contains("conversation=direct") != true
        let controller = ConversationViewController(
            store: store,
            options: ConversationPresentationOptions(trailingSymbol: "video")
        )
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "conversation", value: isGroup ? "direct" : "group")]
        if let otherURL = components?.url {
            let other = ConversationStore(backend: ConversationSimBackend(endpoint: otherURL))
            other.start()
            let badge = ConversationUnreadBadge(stores: [store, other])
            badge.onChange = { [weak controller, weak badge, weak store] in
                guard let controller, let badge, let store else { return }
                controller.setBackUnreadCount(badge.total(excluding: store))
            }
            context.coordinator.others = [other]
            context.coordinator.badge = badge
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.setNavigationBarHidden(true, animated: false)
        return navigation
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
#endif
