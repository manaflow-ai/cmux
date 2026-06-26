#if os(iOS)
import SwiftUI

struct ChatKeyboardTrackingContainer<Transcript: View, Composer: View>: UIViewControllerRepresentable {
    let transcript: Transcript
    let composer: Composer
    let showsComposer: Bool

    func makeUIViewController(
        context: Context
    ) -> ChatKeyboardTrackingViewController<ChatKeyboardTrackedRoot<Transcript>, ChatKeyboardTrackedRoot<Composer>> {
        let controller = ChatKeyboardTrackingViewController(
            transcriptView: ChatKeyboardTrackedRoot(
                content: transcript,
                ignoredContainerEdges: .top
            ),
            composerView: ChatKeyboardTrackedRoot(content: composer),
            showsComposer: showsComposer
        )
        controller.transcriptView = trackedTranscriptRoot(for: controller)
        return controller
    }

    func updateUIViewController(
        _ uiViewController: ChatKeyboardTrackingViewController<ChatKeyboardTrackedRoot<Transcript>, ChatKeyboardTrackedRoot<Composer>>,
        context: Context
    ) {
        uiViewController.transcriptView = trackedTranscriptRoot(for: uiViewController)
        uiViewController.composerView = ChatKeyboardTrackedRoot(content: composer)
        uiViewController.showsComposer = showsComposer
    }

    private func trackedTranscriptRoot(
        for controller: ChatKeyboardTrackingViewController<
            ChatKeyboardTrackedRoot<Transcript>,
            ChatKeyboardTrackedRoot<Composer>
        >
    ) -> ChatKeyboardTrackedRoot<Transcript> {
        ChatKeyboardTrackedRoot(
            content: transcript,
            ignoredContainerEdges: .top,
            onScrollButtonFrameChange: { [weak controller] frame in
                controller?.excludedKeyboardDismissFrame = frame
            }
        )
    }
}
#endif
