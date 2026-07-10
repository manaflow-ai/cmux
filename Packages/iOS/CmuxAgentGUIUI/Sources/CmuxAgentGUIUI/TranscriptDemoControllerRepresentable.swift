#if DEBUG && os(iOS)
import CmuxAgentGUIProjection
import SwiftUI
import UIKit

struct TranscriptDemoControllerRepresentable: UIViewControllerRepresentable {
    let input: TranscriptProjectionInput
    let focusToken: Int
    let jumpToken: Int

    func makeUIViewController(context: Context) -> TranscriptDemoContainerViewController {
        let controller = TranscriptDemoContainerViewController()
        controller.apply(input: input)
        return controller
    }

    func updateUIViewController(_ controller: TranscriptDemoContainerViewController, context: Context) {
        controller.apply(input: input)
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            controller.focusDemoField()
        }
        if context.coordinator.jumpToken != jumpToken {
            context.coordinator.jumpToken = jumpToken
            controller.scrollToBottom()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var focusToken = 0
        var jumpToken = 0
    }
}
#endif
