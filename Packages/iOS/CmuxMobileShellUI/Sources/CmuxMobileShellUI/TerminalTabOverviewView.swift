import CmuxMobileShellModel
import SwiftUI

#if os(iOS)
import UIKit

/// Keeps the terminal mounted while UIKit presents its inverse zoom to the grid.
@MainActor
struct TerminalTabOverviewView: UIViewControllerRepresentable {
    let isPresented: Bool
    let workspaceName: String
    let items: [TerminalTabOverviewItem]
    let canCloseTabs: Bool
    let onSelect: (MobileTerminalPreview.ID) -> Void
    let onClose: (MobileTerminalPreview.ID) -> Void
    let onNewTerminal: () -> Void
    let onReorder: ([MobileTerminalPreview.ID]) -> Void
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> TerminalTabOverviewPresentationController {
        TerminalTabOverviewPresentationController()
    }

    func updateUIViewController(_ controller: TerminalTabOverviewPresentationController, context: Context) {
        controller.update(self)
    }

    static func dismantleUIViewController(_ controller: TerminalTabOverviewPresentationController, coordinator: ()) {
        controller.stop()
    }
}
#endif
