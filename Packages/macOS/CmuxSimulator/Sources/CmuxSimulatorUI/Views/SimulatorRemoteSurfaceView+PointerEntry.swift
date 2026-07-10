import AppKit
import CmuxSimulator

struct SimulatorPendingPointerEntry {
    enum Source {
        case surface
        case stageHalo
    }

    var previousLocation: CGPoint
    let optionPinch: Bool
    let parallelPan: Bool
    let source: Source
}

extension SimulatorRemoteSurfaceView {
    static let stagePointerCaptureInset = SimulatorDeviceStageMetrics.devicePadding

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

struct SimulatorPointerEntry {
    let location: CGPoint
    let edge: SimulatorEdge
}

func simulatorPointerEntry(
    from start: CGPoint,
    to end: CGPoint,
    displayRect rect: CGRect
) -> SimulatorPointerEntry? {
    guard rect.width > 0, rect.height > 0 else { return nil }

    let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
    var entry = CGFloat.zero
    var exit = CGFloat(1)
    var entryEdge = SimulatorEdge.none
    var entryNormalMagnitude = CGFloat.zero

    func clip(
        _ direction: CGFloat,
        _ distance: CGFloat,
        edge: SimulatorEdge,
        normalMagnitude: CGFloat
    ) -> Bool {
        if abs(direction) < .ulpOfOne {
            return distance >= 0
        }
        let ratio = distance / direction
        if direction < 0 {
            if ratio > entry
                || abs(ratio - entry) < .ulpOfOne
                    && normalMagnitude >= entryNormalMagnitude
            {
                entry = ratio
                entryEdge = edge
                entryNormalMagnitude = normalMagnitude
            }
        } else {
            exit = min(exit, ratio)
        }
        return entry <= exit
    }

    guard clip(
        -delta.x,
        start.x - rect.minX,
        edge: .left,
        normalMagnitude: abs(delta.x)
    ), clip(
        delta.x,
        rect.maxX - start.x,
        edge: .right,
        normalMagnitude: abs(delta.x)
    ), clip(
        -delta.y,
        start.y - rect.minY,
        edge: .bottom,
        normalMagnitude: abs(delta.y)
    ), clip(
        delta.y,
        rect.maxY - start.y,
        edge: .top,
        normalMagnitude: abs(delta.y)
    ),
          (0...1).contains(entry)
    else { return nil }

    return SimulatorPointerEntry(
        location: CGPoint(
            x: min(max(start.x + (delta.x * entry), rect.minX), rect.maxX),
            y: min(max(start.y + (delta.y * entry), rect.minY), rect.maxY)
        ),
        edge: entryEdge
    )
}
