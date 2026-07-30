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
}

func simulatorAgentCursorPlan(
    for action: SimulatorControlAction,
    display: SimulatorDisplayMetadata?
) -> SimulatorAgentCursorPlan? {
    guard case let .interactive(interactiveAction) = action else { return nil }
    let events: [SimulatorPointerEvent]
    let durationMilliseconds: Int
    switch interactiveAction {
    case let .gesture(pointerEvents):
        events = pointerEvents
        durationMilliseconds = simulatorDefaultGestureDurationMilliseconds(pointerEvents)
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
    return SimulatorAgentCursorPlan(
        origin: origin,
        destination: destination,
        durationMilliseconds: durationMilliseconds,
        beginsTouch: beginsTouch,
        completionPhase: completionPhase
    )
}

private func simulatorDefaultGestureDurationMilliseconds(
    _ events: [SimulatorPointerEvent]
) -> Int {
    guard events.count > 1 else { return 0 }
    let first = events[0]
    let last = events[events.index(before: events.endIndex)]
    let isTap = events.count == 2
        && first.phase == .began
        && last.phase == .ended
        && first.primary == last.primary
        && first.secondary == last.secondary
        && first.edge == last.edge
    return isTap ? 50 : (events.count - 1) * 4
}
