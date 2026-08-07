import AppKit

/// Ground-truth exits for a workspace drag that never reaches a drop callback.
/// AppKit delivers event-monitor callbacks on the main thread, so one synchronous
/// bridge ends the matching session without a deferred cleanup race.
@MainActor
final class SidebarWorkspaceDragLifecycleMonitor {
    private static let escapeKeyCode: UInt16 = 53

    private let sessionId: UUID
    private let isLeftMouseButtonPressed: @MainActor () -> Bool
    private let onRequestEnd: @MainActor (UUID) -> Void
    // Registration tokens are mutated only by main-actor start/stop. Deinit
    // reads them after the monitor's last owner has released it, when no
    // actor-isolated access can remain in flight.
    private nonisolated(unsafe) var appResignObserver: (any NSObjectProtocol)?
    private nonisolated(unsafe) var keyDownMonitor: Any?
    private nonisolated(unsafe) var localMouseUpMonitor: Any?
    private nonisolated(unsafe) var globalMouseUpMonitor: Any?
    private var endRequested = false
    private var isStopped = false

    init(
        sessionId: UUID,
        isLeftMouseButtonPressed: @escaping @MainActor () -> Bool,
        onRequestEnd: @escaping @MainActor (UUID) -> Void
    ) {
        self.sessionId = sessionId
        self.isLeftMouseButtonPressed = isLeftMouseButtonPressed
        self.onRequestEnd = onRequestEnd
    }

    deinit {
        Self.removeRegistrations(
            appResignObserver: appResignObserver,
            keyDownMonitor: keyDownMonitor,
            localMouseUpMonitor: localMouseUpMonitor,
            globalMouseUpMonitor: globalMouseUpMonitor
        )
    }

    func start() {
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.requestEndFromMainThreadCallback()
        }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == Self.escapeKeyCode {
                self?.requestEndFromMainThreadCallback()
            }
            return event
        }
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.requestEndFromMainThreadCallback()
            return event
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.requestEndFromMainThreadCallback()
        }
        if !isLeftMouseButtonPressed() {
            requestEnd()
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        Self.removeRegistrations(
            appResignObserver: appResignObserver,
            keyDownMonitor: keyDownMonitor,
            localMouseUpMonitor: localMouseUpMonitor,
            globalMouseUpMonitor: globalMouseUpMonitor
        )
        appResignObserver = nil
        keyDownMonitor = nil
        localMouseUpMonitor = nil
        globalMouseUpMonitor = nil
    }

    private nonisolated func requestEndFromMainThreadCallback() {
        MainActor.assumeIsolated {
            requestEnd()
        }
    }

    private func requestEnd() {
        guard !isStopped, !endRequested else { return }
        endRequested = true
        onRequestEnd(sessionId)
    }

    private nonisolated static func removeRegistrations(
        appResignObserver: (any NSObjectProtocol)?,
        keyDownMonitor: Any?,
        localMouseUpMonitor: Any?,
        globalMouseUpMonitor: Any?
    ) {
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
        }
    }
}
