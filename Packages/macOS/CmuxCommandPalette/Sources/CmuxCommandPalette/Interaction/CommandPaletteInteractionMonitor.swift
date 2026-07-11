import AppKit

/// The interaction that ended one visible command-palette lifecycle.
public enum CommandPaletteInteractionDismissal: Sendable, Equatable {
    /// A process-local pointer event occurred outside the palette panel.
    case pointer(CommandPalettePointerEvent)

    /// The palette's host window stopped being the key window.
    case windowResignedKey
}

/// Owns every process-level observation used while one command palette is visible.
///
/// Activation is idempotent for a window: repeated render updates refresh the
/// callbacks without installing duplicate monitors. Deactivation removes the
/// local pointer monitor and both window-key observers as one lifecycle unit.
@MainActor
public final class CommandPaletteInteractionMonitor {
    static let windowDidBecomeKeyNotification = NSWindow.didBecomeKeyNotification
    static let windowDidResignKeyNotification = NSWindow.didResignKeyNotification
    private let notificationCenter: NotificationCenter
    private let eventSource: any CommandPaletteEventMonitorSource
    private weak var window: AnyObject?
    private var localMouseDownMonitor: Any?
    private var windowObserverTokens: [any NSObjectProtocol] = []
    private var shouldDismiss: ((CommandPalettePointerEvent) -> Bool)?
    private var onWindowStateChange: (() -> Void)?
    private var onDismiss: ((CommandPaletteInteractionDismissal) -> Void)?

    /// Creates a monitor backed by the process event stream and default notification center.
    public convenience init() {
        self.init(
            notificationCenter: .default,
            eventSource: AppKitCommandPaletteEventMonitorSource()
        )
    }

    init(
        notificationCenter: NotificationCenter,
        eventSource: any CommandPaletteEventMonitorSource
    ) {
        self.notificationCenter = notificationCenter
        self.eventSource = eventSource
    }

    isolated deinit {
        deactivate()
    }

    /// Starts observation for `window`, or refreshes the callbacks when already active.
    ///
    /// Callers should disable their overlay synchronously in `onDismiss`, allowing
    /// the initiating mouse-down to reach the newly exposed underlying control.
    ///
    /// - Parameters:
    ///   - window: The window object used to scope key-window notifications.
    ///   - shouldDismiss: Returns whether a local mouse-down is outside the palette.
    ///   - onWindowStateChange: Reconciles focus when the observed window changes key state.
    ///   - onDismiss: Synchronously hides the overlay and updates presentation state.
    public func activate(
        for window: AnyObject,
        shouldDismiss: @escaping (CommandPalettePointerEvent) -> Bool,
        onWindowStateChange: @escaping () -> Void,
        onDismiss: @escaping (CommandPaletteInteractionDismissal) -> Void
    ) {
        if self.window !== window {
            deactivate()
            self.window = window
        }

        self.shouldDismiss = shouldDismiss
        self.onWindowStateChange = onWindowStateChange
        self.onDismiss = onDismiss

        if localMouseDownMonitor == nil {
            localMouseDownMonitor = eventSource.addLocalMouseDownMonitor(for: window) { [weak self] event in
                guard let self, self.shouldDismiss?(event) == true else { return }
                self.onDismiss?(.pointer(event))
            }
        }

        guard windowObserverTokens.isEmpty else { return }
        windowObserverTokens = [
            observe(Self.windowDidBecomeKeyNotification, window: window, dismissal: nil),
            observe(Self.windowDidResignKeyNotification, window: window, dismissal: .windowResignedKey),
        ]
    }

    /// Removes all observation and releases the callbacks captured for presentation.
    public func deactivate() {
        if let localMouseDownMonitor {
            eventSource.removeLocalMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        for token in windowObserverTokens {
            notificationCenter.removeObserver(token)
        }
        windowObserverTokens.removeAll()
        window = nil
        shouldDismiss = nil
        onWindowStateChange = nil
        onDismiss = nil
    }

    private func observe(
        _ name: Notification.Name,
        window: AnyObject,
        dismissal: CommandPaletteInteractionDismissal?
    ) -> any NSObjectProtocol {
        notificationCenter.addObserver(
            forName: name,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onWindowStateChange?()
                if let dismissal {
                    self.onDismiss?(dismissal)
                }
            }
        }
    }
}
