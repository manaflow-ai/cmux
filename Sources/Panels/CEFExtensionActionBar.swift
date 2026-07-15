import CEFKit
import SwiftUI

/// Displays popup-capable staged Chrome extensions in a CEF pane's omnibar.
struct CEFExtensionActionBar: View {
    let panel: CEFBrowserPanel
    @State private var actions: [CEFExtensionAction] = []
    @State private var popoverController: CEFExtensionPopoverController?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(actions) { action in
                CEFExtensionActionButton(action: action) { anchorView in
                    showPopover(for: action, relativeTo: anchorView)
                }
                .frame(width: 22, height: 22)
            }
        }
        .onAppear {
            reloadActions()
            CEFApp.shared.onContextInitialized {
                reloadActions()
            }
        }
        .onDisappear {
            popoverController?.close()
            popoverController = nil
        }
    }

    private func reloadActions() {
        actions = CEFExtensionActionLoader().load(
            from: CEFApp.shared.stagedExtensionDirectories
        )
    }

    private func showPopover(
        for action: CEFExtensionAction,
        relativeTo anchorView: NSView
    ) {
        popoverController?.close()
        let controller = CEFExtensionPopoverController()
        popoverController = controller
        controller.show(
            action: action,
            profile: panel.resolveCEFProfileForChildBrowser(),
            relativeTo: anchorView
        )
    }
}
