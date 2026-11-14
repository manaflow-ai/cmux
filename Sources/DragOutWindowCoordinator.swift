import AppKit
import CmuxFoundation

/// Observes release evidence without changing the native drag's ownership or event stream.
@MainActor
final class DragOutWindowCoordinator {
    private let windows: () -> [NSWindow]
    private var eventMonitor: Any?
    private var lastMouseUp: TimeInterval = -.infinity
    private var lastEscape: TimeInterval = -.infinity
    private let policy = DragOutWindowPolicy()

    init(windows: @escaping () -> [NSWindow]) {
        self.windows = windows
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { [weak self] event in
            self?.observe(event)
            return event
        }
    }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    private func observe(_ event: NSEvent) {
        if event.type == .leftMouseUp { lastMouseUp = event.timestamp }
        if event.type == .keyDown && event.keyCode == 53 { lastEscape = event.timestamp }
    }

    func shouldDetach(beganAt: TimeInterval, point: NSPoint, operation: NSDragOperation) -> Bool {
        // AppKit may deliver its terminal event directly during the native tracking loop.
        if let event = NSApp.currentEvent { observe(event) }
        let shouldDetach = policy.shouldDetach(
            accepted: !operation.isEmpty,
            mouseReleased: lastMouseUp >= beganAt && NSEvent.pressedMouseButtons & 1 == 0,
            cancelled: lastEscape >= beganAt,
            point: point,
            windowFrames: windows().filter { $0.isVisible && !$0.isMiniaturized }.map(\.frame)
        )
#if DEBUG
        cmuxDebugLog("window.drag.complete accepted=\(!operation.isEmpty) released=\(lastMouseUp >= beganAt) cancelled=\(lastEscape >= beganAt) detach=\(shouldDetach)")
#endif
        return shouldDetach
    }

    func place(_ window: NSWindow, near point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
            ?? window.screen ?? NSScreen.main else { return }
        window.setFrame(policy.frame(size: window.frame.size, near: point, visibleFrame: screen.visibleFrame), display: true)
    }
}
