import AppKit
import CEFKit

/// Routes pointer activation in a CEF host back to its owning cmux pane.
@MainActor
final class CEFBrowserHostCoordinator {
    private let registrationID: ObjectIdentifier
    static let usesSharedEventMonitor = true

    private final class Registration {
        weak var containerView: CEFBrowserContainerView?
        let onRequestPanelFocus: () -> Void

        init(containerView: CEFBrowserContainerView, onRequestPanelFocus: @escaping () -> Void) {
            self.containerView = containerView
            self.onRequestPanelFocus = onRequestPanelFocus
        }
    }

    private static var registrations: [ObjectIdentifier: Registration] = [:]
    private static var eventMonitor: Any?

    init(
        containerView: CEFBrowserContainerView,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        registrationID = ObjectIdentifier(containerView)
        Self.registrations[registrationID] = Registration(
            containerView: containerView,
            onRequestPanelFocus: onRequestPanelFocus
        )
        Self.installEventMonitorIfNeeded()
    }

    private static func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            routeMouseDown(event)
            return event
        }
    }

    private static func routeMouseDown(_ event: NSEvent) {
        guard let contentView = event.window?.contentView else { return }
        let hitPoint = contentView.convert(event.locationInWindow, from: nil)
        var hitView = contentView.hitTest(hitPoint)
        while let view = hitView {
            if let registration = registrations[ObjectIdentifier(view)],
               registration.containerView === view,
               !view.isHiddenOrHasHiddenAncestor {
                registration.onRequestPanelFocus()
                return
            }
            hitView = view.superview
        }
    }

    deinit {
        Self.registrations.removeValue(forKey: registrationID)
        if Self.registrations.isEmpty, let eventMonitor = Self.eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            Self.eventMonitor = nil
        }
    }
}
