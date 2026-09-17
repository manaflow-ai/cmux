import AppKit
import CmuxSimulator

extension SimulatorRemoteSurfaceView {
    static let stagePointerCaptureInset = simulatorDeviceStagePadding

    var pointerEntryCaptureRect: CGRect {
        bounds.insetBy(
            dx: -Self.stagePointerCaptureInset,
            dy: -Self.stagePointerCaptureInset
        )
    }

    func installStagePointerMonitor(for window: NSWindow) {
        guard isPointerInputEnabled else { return }
        removeStagePointerMonitor()
        stagePointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self, weak window] event in
            guard let self,
                  let window,
                  self.window === window,
                  event.window === window,
                  self.isPointerInputEnabled,
                  window.isVisible,
                  !self.isHiddenOrHasHiddenAncestor,
                  !self.visibleRect.isEmpty
            else { return event }

            return self.handleStagePointerEvent(event)
        }
    }

    func removeStagePointerMonitor() {
        guard let stagePointerMonitor else { return }
        NSEvent.removeMonitor(stagePointerMonitor)
        self.stagePointerMonitor = nil
    }

    func handleStagePointerEvent(_ event: NSEvent) -> NSEvent {
        guard isPointerInputEnabled else { return event }
        let location = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            guard !bounds.contains(location),
                  pointerEntryCaptureRect.contains(location),
                  pointerEntryEventFilter?(event) ?? true
            else { return event }
            beginPointerInteraction(with: event, source: .stageHalo)
            return event
        case .leftMouseDragged:
            guard pendingPointerEntry?.source == .stageHalo || stageHaloPointerActive else {
                return event
            }
            mouseDragged(with: event)
            return event
        case .leftMouseUp:
            guard pendingPointerEntry?.source == .stageHalo || stageHaloPointerActive else {
                return event
            }
            mouseUp(with: event)
            return event
        default:
            return event
        }
    }
}
