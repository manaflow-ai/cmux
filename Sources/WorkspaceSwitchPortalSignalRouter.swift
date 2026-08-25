import AppKit
import Foundation

/// Relays portal readiness notifications only to the owning main window.
@MainActor
final class WorkspaceSwitchPortalSignalRouter {
    let notificationCenter = NotificationCenter()

    private let sourceNotificationCenter: NotificationCenter
    private weak var window: NSWindow?
    private var globalObservers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        sourceNotificationCenter = notificationCenter
        let names: [Notification.Name] = [
            .terminalPortalVisibilityDidChange,
            .terminalSurfaceHostedViewDidMoveToWindow,
            .terminalPortalDidBecomePresentable,
            .browserPortalRegistryDidChange,
            .browserPortalDidBecomePresentable,
        ]
        globalObservers = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.relayIfOwned(notification)
                }
            }
        }
    }

    deinit {
        for observer in globalObservers {
            sourceNotificationCenter.removeObserver(observer)
        }
    }

    func attach(to window: NSWindow?) {
        self.window = window
    }

    func publisher(for name: Notification.Name) -> NotificationCenter.Publisher {
        notificationCenter.publisher(for: name)
    }

    private func relayIfOwned(_ notification: Notification) {
        guard let window,
              let sourceWindow = sourceWindow(for: notification),
              sourceWindow === window else {
            return
        }
        notificationCenter.post(
            name: notification.name,
            object: notification.object,
            userInfo: notification.userInfo
        )
    }

    private func sourceWindow(for notification: Notification) -> NSWindow? {
        if let view = notification.object as? NSView {
            return view.window
        }
        if let surface = notification.object as? TerminalSurface {
            return surface.hostedView.window
        }
        return nil
    }
}
