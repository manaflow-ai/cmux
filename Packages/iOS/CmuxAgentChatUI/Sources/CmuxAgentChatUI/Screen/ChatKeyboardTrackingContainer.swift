#if os(iOS)
import SwiftUI

struct ChatKeyboardTrackingContainer<Transcript: View, Composer: View>: UIViewControllerRepresentable {
    let transcript: Transcript
    let composer: Composer
    let showsComposer: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(
        context: Context
    ) -> ChatKeyboardTrackingViewController<ChatKeyboardTrackedRoot<Transcript>, ChatKeyboardTrackedRoot<Composer>> {
        let controller = ChatKeyboardTrackingViewController(
            transcriptView: ChatKeyboardTrackedRoot(
                content: transcript,
                ignoredContainerEdges: .top,
                overlayGeometry: context.coordinator.overlayGeometry
            ),
            composerView: ChatKeyboardTrackedRoot(content: composer),
            showsComposer: showsComposer
        )
        controller.transcriptOverlayGeometry = context.coordinator.overlayGeometry
        controller.transcriptView = trackedTranscriptRoot(for: controller)
        return controller
    }

    func updateUIViewController(
        _ uiViewController: ChatKeyboardTrackingViewController<ChatKeyboardTrackedRoot<Transcript>, ChatKeyboardTrackedRoot<Composer>>,
        context: Context
    ) {
        uiViewController.transcriptOverlayGeometry = context.coordinator.overlayGeometry
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
            overlayGeometry: controller.transcriptOverlayGeometry,
            onScrollButtonFrameChange: { [weak controller] frame in
                controller?.excludedKeyboardDismissFrame = frame
            }
        )
    }

    @MainActor
    final class Coordinator {
        let overlayGeometry = ChatTranscriptOverlayGeometry()
    }
}
#endif
