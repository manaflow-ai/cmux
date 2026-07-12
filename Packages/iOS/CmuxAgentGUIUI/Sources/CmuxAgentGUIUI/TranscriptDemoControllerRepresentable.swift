#if DEBUG && os(iOS)
import CmuxAgentGUIProjection
import SwiftUI
import UIKit

struct TranscriptDemoControllerRepresentable: UIViewControllerRepresentable {
    let input: TranscriptProjectionInput
    let theme: AgentGUITheme
    let jumpToken: Int
    let bottomChromeHeight: CGFloat

    func makeUIViewController(context: Context) -> TranscriptDemoContainerViewController {
        let controller = TranscriptDemoContainerViewController(theme: theme)
        controller.apply(input: input)
        controller.setBottomChromeHeight(bottomChromeHeight)
        return controller
    }

    func updateUIViewController(_ controller: TranscriptDemoContainerViewController, context: Context) {
        controller.apply(theme: theme)
        controller.apply(input: input)
        controller.setBottomChromeHeight(bottomChromeHeight)
        if context.coordinator.jumpToken != jumpToken {
            context.coordinator.jumpToken = jumpToken
            controller.scrollToBottom()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var jumpToken = 0
    }
}
#endif
