import CmuxFeedback
import SwiftUI

/// Transitional mount for the native feedback controller while the parent
/// window is still being moved to its AppKit controller.
struct NativeFeedbackComposerBridge: NSViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeNSViewController(context: Context) -> SidebarFeedbackComposerSheet {
        let coordinator = context.coordinator
        return SidebarFeedbackComposerSheet {
            coordinator.dismiss()
        }
    }

    func updateNSViewController(
        _ viewController: SidebarFeedbackComposerSheet,
        context: Context
    ) {
        context.coordinator.dismissAction = dismiss
    }

    @MainActor
    final class Coordinator {
        var dismissAction: DismissAction

        init(dismiss: DismissAction) {
            dismissAction = dismiss
        }

        func dismiss() {
            dismissAction()
        }
    }
}
