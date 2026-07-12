import AppKit
import CEFKit

/// Routes pointer activation in a CEF host back to its owning cmux pane.
@MainActor
final class CEFBrowserHostCoordinator {
    private weak var containerView: CEFBrowserContainerView?
    private let onRequestPanelFocus: () -> Void
    private var eventMonitor: Any?

    init(
        containerView: CEFBrowserContainerView,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        self.containerView = containerView
        self.onRequestPanelFocus = onRequestPanelFocus
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self,
                  let containerView = self.containerView,
                  event.window === containerView.window,
                  !containerView.isHiddenOrHasHiddenAncestor,
                  self.eventTargetsContainer(event, containerView: containerView) else {
                return event
            }

            self.onRequestPanelFocus()
            return event
        }
    }

    private func eventTargetsContainer(
        _ event: NSEvent,
        containerView: CEFBrowserContainerView
    ) -> Bool {
        guard let contentView = event.window?.contentView else { return false }
        let hitPoint = contentView.convert(event.locationInWindow, from: nil)
        var hitView = contentView.hitTest(hitPoint)
        while let view = hitView {
            if view === containerView { return true }
            hitView = view.superview
        }
        return false
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}
