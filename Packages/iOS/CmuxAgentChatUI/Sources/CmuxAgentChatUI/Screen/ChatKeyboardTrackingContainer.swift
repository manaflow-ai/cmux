#if os(iOS)
import SwiftUI

struct ChatKeyboardTrackingContainer<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(
        context: Context
    ) -> ChatKeyboardTrackingViewController<ChatKeyboardTrackedRoot<Content>> {
        ChatKeyboardTrackingViewController(rootView: ChatKeyboardTrackedRoot(content: content))
    }

    func updateUIViewController(
        _ uiViewController: ChatKeyboardTrackingViewController<ChatKeyboardTrackedRoot<Content>>,
        context: Context
    ) {
        uiViewController.rootView = ChatKeyboardTrackedRoot(content: content)
    }
}
#endif
