#if os(iOS)
import SwiftUI

/// Transitional bridge from the remaining screen shell into the native chat controller tree.
struct ChatKeyboardTrackingContainer: UIViewControllerRepresentable {
    let transcriptConfiguration: ChatTranscriptTableConfiguration
    let composerConfiguration: ChatComposerNativeConfiguration
    let showsComposer: Bool

    func makeUIViewController(context: Context) -> ChatKeyboardTrackingViewController {
        let transcript = ChatTranscriptNativeView()
        transcript.update(configuration: transcriptConfiguration)
        let composer = ChatComposerNativeView(configuration: composerConfiguration)
        let controller = ChatKeyboardTrackingViewController(
            transcriptView: transcript,
            composerView: composer,
            showsComposer: showsComposer
        )
        transcript.onScrollButtonFrameChanged = { [weak controller] frame in
            controller?.excludedKeyboardDismissFrame = frame
        }
        composer.onIntrinsicHeightChanged = { [weak controller] in
            controller?.view.setNeedsLayout()
        }
        return controller
    }

    func updateUIViewController(
        _ controller: ChatKeyboardTrackingViewController,
        context: Context
    ) {
        (controller.transcriptView as? ChatTranscriptNativeView)?.update(
            configuration: transcriptConfiguration
        )
        (controller.composerView as? ChatComposerNativeView)?.update(
            configuration: composerConfiguration
        )
        controller.showsComposer = showsComposer
    }
}
#endif
