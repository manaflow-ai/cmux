import CmuxSimulator

/// Cursor motion derived from one worker-bound pointer action.
struct SimulatorAgentCursorPlan: Equatable, Sendable {
    /// Display-normalized first touch point.
    let origin: SimulatorPoint
    /// Display-normalized final touch point.
    let destination: SimulatorPoint
    /// Duration used by the worker for the matching input sequence.
    let durationMilliseconds: Int
    /// Whether the sequence contains a touch-down event.
    let beginsTouch: Bool
    /// Phase to render after the worker returns, or nil while touch remains down.
    let completionPhase: SimulatorAgentCursorPhase?

    init?(
        action: SimulatorControlAction,
        display: SimulatorDisplayMetadata?
    ) {
        guard case let .interactive(interactiveAction) = action else { return nil }
        let events: [SimulatorPointerEvent]
        let durationMilliseconds: Int
        switch interactiveAction {
        case let .gesture(pointerEvents):
            events = pointerEvents
            if pointerEvents.count > 1 {
                let first = pointerEvents[0]
                let last = pointerEvents[pointerEvents.index(before: pointerEvents.endIndex)]
                let isTap = pointerEvents.count == 2
                    && first.phase == .began
                    && last.phase == .ended
                    && first.primary == last.primary
                    && first.secondary == last.secondary
                    && first.edge == last.edge
                durationMilliseconds = isTap ? 50 : (pointerEvents.count - 1) * 4
            } else {
                durationMilliseconds = 0
            }
        case let .timedGesture(pointerEvents, duration):
            events = pointerEvents
            durationMilliseconds = duration
        case let .touch(pointerEvents, holdMilliseconds):
            events = pointerEvents
            durationMilliseconds = holdMilliseconds
        case .keyPresses, .keyChord, .typeText, .hardwareButton,
             .hardwareButtonHold, .rotate, .coreAnimation, .memoryWarning:
            return nil
        }
        guard let first = events.first, let last = events.last else { return nil }
        let geometry = display.map(SimulatorOrientationGeometry.init(display:))
        let origin = geometry?.displayPoint(for: first.primary) ?? first.primary
        let destination = geometry?.displayPoint(for: last.primary) ?? last.primary
        let beginsTouch = events.contains(where: { $0.phase == .began })
        let completionPhase: SimulatorAgentCursorPhase?
        if events.contains(where: { $0.phase == .cancelled }) {
            completionPhase = .cancelled
        } else if events.contains(where: { $0.phase == .ended }) {
            completionPhase = .clicked
        } else {
            completionPhase = nil
        }
        self.origin = origin
        self.destination = destination
        self.durationMilliseconds = durationMilliseconds
        self.beginsTouch = beginsTouch
        self.completionPhase = completionPhase
    }
}
