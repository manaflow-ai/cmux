import AppKit

/// Ground-truth exits for a workspace drag that never reaches a drop callback.
/// Requests are enqueued after AppKit's event monitor returns, allowing a real
/// drop to finish first. The coordinator's session token rejects stale requests.
@MainActor
final class SidebarWorkspaceDragLifecycleMonitor {
    private static let escapeKeyCode: UInt16 = 53

    private let sessionId: UUID
    private let onRequestEnd: @MainActor (UUID) -> Void
    private var appResignObserver: (any NSObjectProtocol)?
    private var keyDownMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var endRequested = false
    private var isStopped = false

    init(sessionId: UUID, onRequestEnd: @escaping @MainActor (UUID) -> Void) {
        self.sessionId = sessionId
        self.onRequestEnd = onRequestEnd
    }

    func start() {
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.requestEnd()
        }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == Self.escapeKeyCode {
                self?.requestEnd()
            }
            return event
        }
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.requestEnd()
            return event
        }
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.requestEnd()
        }
        if !CGEventSource.buttonState(.combinedSessionState, button: .left) {
            requestEnd()
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let localMouseUpMonitor {
            NSEvent.removeMonitor(localMouseUpMonitor)
            self.localMouseUpMonitor = nil
        }
        if let globalMouseUpMonitor {
            NSEvent.removeMonitor(globalMouseUpMonitor)
            self.globalMouseUpMonitor = nil
        }
    }

    private nonisolated func requestEnd() {
        Task { @MainActor [weak self] in
            guard let self, !self.isStopped, !self.endRequested else { return }
            self.endRequested = true
            self.onRequestEnd(self.sessionId)
        }
    }
}
