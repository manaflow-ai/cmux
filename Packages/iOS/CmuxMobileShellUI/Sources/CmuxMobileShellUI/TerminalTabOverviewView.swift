import CmuxMobileShellModel
import SwiftUI

#if os(iOS)
import UIKit

/// SwiftUI hosts the screen while UIKit owns the Safari-shaped layout and
/// interaction states. The measured tab geometry stays stable across updates.
@MainActor
struct TerminalTabOverviewView: UIViewControllerRepresentable {
    let workspaceName: String
    let items: [TerminalTabOverviewItem]
    let canCloseTabs: Bool
    let onSelect: (MobileTerminalPreview.ID) -> Void
    let onClose: (MobileTerminalPreview.ID) -> Void
    let onNewTerminal: () -> Void
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> TerminalTabOverviewViewController {
        TerminalTabOverviewViewController(
            workspaceName: workspaceName,
            items: items,
            canCloseTabs: canCloseTabs,
            onSelect: onSelect,
            onClose: onClose,
            onNewTerminal: onNewTerminal,
            onDone: onDone
        )
    }

    func updateUIViewController(_ viewController: TerminalTabOverviewViewController, context: Context) {
        viewController.update(
            workspaceName: workspaceName,
            items: items,
            canCloseTabs: canCloseTabs,
            onSelect: onSelect,
            onClose: onClose,
            onNewTerminal: onNewTerminal,
            onDone: onDone
        )
    }

    static func dismantleUIViewController(_ viewController: TerminalTabOverviewViewController, coordinator: ()) {
        viewController.stopTransitions()
    }
}
#endif
