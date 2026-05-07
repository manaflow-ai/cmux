import AppKit
import SwiftUI

@MainActor
extension AppDelegate {
    func enqueueRightSidebarVisibilityShortcut(preferredWindow: NSWindow?) {
        Task { @MainActor [weak self, weak preferredWindow] in
            guard let self else { return }
            self.performSidebarVisibilityMutationWithoutAnimations {
                _ = self.toggleRightSidebarInActiveMainWindow(preferredWindow: preferredWindow)
            }
        }
    }

    private func performSidebarVisibilityMutationWithoutAnimations(_ body: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            withTransaction(transaction, body)
            CATransaction.commit()
        }
    }
}
