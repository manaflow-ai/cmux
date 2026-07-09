internal import AppKit
internal import Foundation
public import Observation
import CmuxFoundation

/// Watches for the conditions that would otherwise strand an in-flight sidebar
/// drag (mouse released outside a drop target, app resigned active, escape
/// pressed) and asks the sidebar to clear its drag state after a short debounce.
///
/// Owned by the sidebar view as transient drag-lifecycle state. The view calls
/// ``start(onRequestClear:)`` when a drag begins and ``stop()`` when it ends.
/// All event hooks (NSEvent monitors, the app-resign notification) are torn down
/// in ``stop()`` and the pending clear is cancellable, so the monitor holds no
/// state once a drag completes.
///
/// `@MainActor @Observable` (migrated from `ObservableObject`): the monitor is
/// driven entirely from the main thread by the sidebar's drag lifecycle, and it
/// publishes no observed properties — the view holds it as `@State` purely to own
/// its lifetime, so per-property observation tracking is the faithful successor
/// to the no-`@Published` original.
@MainActor
@Observable
public final class SidebarDragFailsafeMonitor {
    private static let escapeKeyCode: UInt16 = 53

    /// Pending debounced clear; the deadline preserves the legacy
    /// ``SidebarDragFailsafePolicy/clearDelay`` cadence exactly. `asyncAfter` is
    /// retained here (rather than an injected `Clock`) to keep this a byte-faithful
    /// lift of the original failsafe timing; converting it to a cancellable
    /// `Clock`-driven sleep is a separate modernization that would change the
    /// observable clear cadence.
    @ObservationIgnored private var pendingClearWorkItem: DispatchWorkItem?
    @ObservationIgnored private var appResignObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var keyDownMonitor: Any?
    @ObservationIgnored private var localMouseMonitor: Any?
    @ObservationIgnored private var globalMouseMonitor: Any?
    @ObservationIgnored private var onRequestClear: ((String) -> Void)?

    /// DEBUG-only schedule/fire logger injected by the app composition root so the
    /// monitor keeps emitting `sidebar.dragFailsafe.*` events without the package
    /// depending on the app's `cmuxDebugLog`. `nil` in release.
    @ObservationIgnored private let debugLog: ((_ message: String) -> Void)?

    /// Creates a failsafe monitor.
    /// - Parameter debugLog: Optional DEBUG-only sink for the
    ///   `sidebar.dragFailsafe.schedule`/`.fire` trace events.
    public init(debugLog: ((_ message: String) -> Void)? = nil) {
        self.debugLog = debugLog
    }

    /// Begins watching for failsafe-clear conditions, invoking `onRequestClear`
    /// (with a reason string) when one fires. Safe to call repeatedly; each hook
    /// is installed at most once.
    public func start(onRequestClear: @escaping (String) -> Void) {
        self.onRequestClear = onRequestClear
        if SidebarDragFailsafePolicy().shouldRequestClearWhenMonitoringStarts(
            isLeftMouseButtonDown: CGEventSource.buttonState(
                .combinedSessionState,
                button: .left
            )
        ) {
            requestClearSoon(reason: "mouse_up_failsafe")
        }
        if appResignObserver == nil {
            appResignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.requestClearSoon(reason: "app_resign_active")
                }
            }
        }
        if keyDownMonitor == nil {
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == Self.escapeKeyCode {
                    self?.requestClearSoon(reason: "escape_cancel")
                }
                return event
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                if SidebarDragFailsafePolicy().shouldRequestClear(forMouseEventType: event.type) {
                    self?.requestClearSoon(reason: "mouse_up_failsafe")
                }
                return event
            }
        }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard SidebarDragFailsafePolicy().shouldRequestClear(forMouseEventType: event.type) else { return }
                Task { @MainActor [weak self] in
                    self?.requestClearSoon(reason: "mouse_up_failsafe")
                }
            }
        }
    }

    /// Stops watching and tears down every event hook and the pending clear.
    public func stop() {
        pendingClearWorkItem?.cancel()
        pendingClearWorkItem = nil
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        onRequestClear = nil
    }

    private func requestClearSoon(reason: String) {
        guard pendingClearWorkItem == nil else { return }
        debugLog?("sidebar.dragFailsafe.schedule reason=\(reason)")
        let workItem = DispatchWorkItem { [weak self] in
            self?.debugLog?("sidebar.dragFailsafe.fire reason=\(reason)")
            self?.pendingClearWorkItem = nil
            self?.onRequestClear?(reason)
        }
        pendingClearWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + SidebarDragFailsafePolicy.clearDelay, execute: workItem)
    }
}
