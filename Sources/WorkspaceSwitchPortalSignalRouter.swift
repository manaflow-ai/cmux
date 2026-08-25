import AppKit
import Combine
import Foundation
import WebKit

/// Relays portal readiness notifications only to the owning main window.
@MainActor
final class WorkspaceSwitchPortalSignalRouter {
    let notificationCenter = NotificationCenter()

    private let sourceNotificationCenter: NotificationCenter
    private weak var window: NSWindow?
    private var sourceObservers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        sourceNotificationCenter = notificationCenter
    }

    deinit {
        for observer in sourceObservers {
            sourceNotificationCenter.removeObserver(observer)
        }
    }

    func attach(to window: NSWindow?) {
        self.window = window
    }

    /// Observes only the surfaces participating in the current handoff.
    func observe(
        terminalHostedView: GhosttySurfaceScrollView?,
        terminalSurface: TerminalSurface?,
        browserWebView: WKWebView?
    ) {
        clearSources()
        let registrations: [(Notification.Name, AnyObject?)] = [
            (.terminalPortalVisibilityDidChange, terminalHostedView),
            (.terminalPortalDidBecomePresentable, terminalHostedView),
            (.terminalSurfaceHostedViewDidMoveToWindow, terminalSurface),
            (.browserPortalRegistryDidChange, browserWebView),
            (.browserPortalDidBecomePresentable, browserWebView),
        ]
        for (name, object) in registrations {
            guard let object else { continue }
            sourceObservers.append(
                sourceNotificationCenter.addObserver(
                    forName: name,
                    object: object,
                    queue: .main
                ) { [weak self] notification in
                    MainActor.assumeIsolated {
                        self?.relayIfOwned(notification)
                    }
                }
            )
        }
    }

    func clearSources() {
        for observer in sourceObservers {
            sourceNotificationCenter.removeObserver(observer)
        }
        sourceObservers.removeAll(keepingCapacity: true)
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
