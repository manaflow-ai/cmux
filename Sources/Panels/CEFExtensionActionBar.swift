import CEFKit
import SwiftUI

func shouldDismissCEFExtensionPopover(isVisibleInUI: Bool) -> Bool {
    !isVisibleInUI
}

/// Displays popup-capable staged Chrome extensions in a CEF pane's omnibar.
struct CEFExtensionActionBar: View {
    let panel: CEFBrowserPanel
    let isVisibleInUI: Bool
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
            dismissPopover()
        }
        .onChange(of: isVisibleInUI) { _, visible in
            if shouldDismissCEFExtensionPopover(isVisibleInUI: visible) {
                dismissPopover()
            }
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
        guard isVisibleInUI else { return }
        dismissPopover()
        let controller = CEFExtensionPopoverController()
        popoverController = controller
        controller.show(
            action: action,
            profile: panel.resolveCEFProfileForChildBrowser(),
            relativeTo: anchorView
        )
    }

    private func dismissPopover() {
        popoverController?.close()
        popoverController = nil
    }
}
