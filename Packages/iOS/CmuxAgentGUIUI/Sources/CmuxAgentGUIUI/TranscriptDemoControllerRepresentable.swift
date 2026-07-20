#if DEBUG && os(iOS)
import CmuxAgentGUIProjection
import SwiftUI
import UIKit

struct TranscriptDemoControllerRepresentable: UIViewControllerRepresentable {
    let input: TranscriptProjectionInput
    let theme: AgentGUITheme
    let jumpToken: Int
    let bottomChromeHeight: CGFloat
    let density: TranscriptDensity
    let composerModel: TranscriptDemoModel?
    let densityBinding: Binding<TranscriptDensity>?
    let onShowActivity: (TranscriptActivityDetails) -> Void

    init(
        input: TranscriptProjectionInput,
        theme: AgentGUITheme,
        jumpToken: Int,
        bottomChromeHeight: CGFloat,
        density: TranscriptDensity,
        composerModel: TranscriptDemoModel? = nil,
        densityBinding: Binding<TranscriptDensity>? = nil,
        onShowActivity: @escaping (TranscriptActivityDetails) -> Void = { _ in }
    ) {
        self.input = input
        self.theme = theme
        self.jumpToken = jumpToken
        self.bottomChromeHeight = bottomChromeHeight
        self.density = density
        self.composerModel = composerModel
        self.densityBinding = densityBinding
        self.onShowActivity = onShowActivity
    }

    func makeUIViewController(context: Context) -> TranscriptDemoContainerViewController {
        let controller = TranscriptDemoContainerViewController(theme: theme)
        controller.setDensity(density)
        controller.apply(input: input)
        controller.applyActivityPresentation(onShowActivity: onShowActivity)
        if let composerModel, let densityBinding {
            controller.installComposer(model: composerModel, density: densityBinding)
        } else {
            controller.setBottomChromeHeight(bottomChromeHeight)
        }
        return controller
    }

    func updateUIViewController(_ controller: TranscriptDemoContainerViewController, context: Context) {
        controller.apply(theme: theme)
        controller.setDensity(density)
        controller.apply(input: input)
        controller.applyActivityPresentation(onShowActivity: onShowActivity)
        if composerModel == nil {
            controller.setBottomChromeHeight(bottomChromeHeight)
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
        var jumpToken = 0
    }
}
#endif
