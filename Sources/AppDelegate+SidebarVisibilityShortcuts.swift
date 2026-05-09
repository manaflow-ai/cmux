import AppKit
import SwiftUI

@MainActor
extension AppDelegate {
    func enqueueLeftSidebarVisibilityShortcut(preferredWindow: NSWindow?) {
        performSidebarVisibilityMutationWithoutAnimations {
            _ = toggleSidebarInActiveMainWindow(preferredWindow: preferredWindow)
        }
    }

    func enqueueRightSidebarVisibilityShortcut(preferredWindow: NSWindow?) {
        performSidebarVisibilityMutationWithoutAnimations {
            _ = toggleRightSidebarInActiveMainWindow(preferredWindow: preferredWindow)
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
