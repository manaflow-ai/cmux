#if os(iOS)
import SwiftUI

struct ChatKeyboardTrackingContainer<Content: View>: UIViewControllerRepresentable {
    let content: Content

    func makeUIViewController(context: Context) -> ChatKeyboardTrackingViewController<Content> {
        ChatKeyboardTrackingViewController(rootView: content)
    }

    func updateUIViewController(_ uiViewController: ChatKeyboardTrackingViewController<Content>, context: Context) {
        uiViewController.rootView = content
    }
}
#endif
