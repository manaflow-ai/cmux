#if os(iOS)
import SwiftUI

struct ChatKeyboardTrackingContainer<Transcript: View, Composer: View>: UIViewControllerRepresentable {
    let transcript: Transcript
    let composer: Composer
    let showsComposer: Bool

    func makeUIViewController(
        context: Context
    ) -> ChatKeyboardTrackingViewController<ChatKeyboardTrackedRoot<Transcript>, ChatKeyboardTrackedRoot<Composer>> {
        ChatKeyboardTrackingViewController(
            transcriptView: ChatKeyboardTrackedRoot(content: transcript),
            composerView: ChatKeyboardTrackedRoot(content: composer),
            showsComposer: showsComposer
        )
    }

    func updateUIViewController(
        _ uiViewController: ChatKeyboardTrackingViewController<ChatKeyboardTrackedRoot<Transcript>, ChatKeyboardTrackedRoot<Composer>>,
        context: Context
    ) {
        uiViewController.transcriptView = ChatKeyboardTrackedRoot(content: transcript)
        uiViewController.composerView = ChatKeyboardTrackedRoot(content: composer)
        uiViewController.showsComposer = showsComposer
    }
}
#endif
