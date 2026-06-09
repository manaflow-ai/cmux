import AppKit
import SwiftUI

@MainActor
final class MenubarSearchPopover: NSObject, NSPopoverDelegate {
    private unowned let coordinator: GlobalSearchCoordinator
    private let popover = NSPopover()

    var isShown: Bool {
        popover.isShown
    }

    init(coordinator: GlobalSearchCoordinator) {
        self.coordinator = coordinator
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 720, height: 460)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: GlobalSearchPaletteView(coordinator: coordinator)
        )
    }

    private var dismissalHandler: (() -> Void)?

    func toggle(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        if popover.isShown {
            dismiss()
        } else {
            show(relativeTo: button, onDismiss: onDismiss)
        }
    }

    func show(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        if popover.isShown {
            popover.performClose(nil)
        }
        dismissalHandler = onDismiss
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func dismiss() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        let handler = dismissalHandler
        dismissalHandler = nil
        handler?()
    }
}
