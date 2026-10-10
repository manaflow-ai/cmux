import Foundation

/// Inputs to the pane state: transport facts and viewer choices.
public nonisolated enum RemotePaneEvent: Sendable, Hashable {
    case status(RemoteViewStatus)
    case frameShown
    case selectMode(RemoteControlMode)
    case controlAnyway
    /// The viewer pressed Stop; the transport closes the session.
    case stop
    /// The viewer pressed Reconnect; a new session starts connecting.
    case reconnect
    case setInteractiveMaxRtt(Int)
}

/// The pane's single writer. Pure: `reduce` maps a state and an event to
/// the next state, and the view renders whatever comes out.
public struct RemotePaneReducer {
    public nonisolated init() {}
    public nonisolated func reduce(_ state: RemotePaneState, _ event: RemotePaneEvent) -> RemotePaneState {
        var next = state
        switch event {
        case let .status(status):
            let wasEnded = if case .ended = state.sessionState { true } else { false }
            next.status = status
            if case .connecting = status.state, wasEnded {
                next.controlDespiteLatency = false
                next.hasFrame = false
            }
        case .frameShown:
            if state.sessionState == .streaming { next.hasFrame = true }
        case let .selectMode(mode):
            next.requestedMode = mode
            if mode == .view { next.controlDespiteLatency = false }
        case .controlAnyway:
            guard state.sessionState == .streaming, state.isHighLatency else { break }
            next.requestedMode = .control
            next.controlDespiteLatency = true
        case .stop:
            guard !state.isEnded else { break }
            var status = state.status ?? RemoteViewStatus(state: .connecting)
            status.state = .ended(.stoppedByViewer)
            next.status = status
        case .reconnect:
            guard state.isEnded else { break }
            var status = state.status ?? RemoteViewStatus(state: .connecting)
            status.state = .connecting
            status.rttMs = nil
            next.status = status
            next.controlDespiteLatency = false
            next.hasFrame = false
        case let .setInteractiveMaxRtt(limit):
            next.interactiveMaxRttMs = max(0, limit)
        }
        return next
    }
}

nonisolated extension RemotePaneState {
    public var isEnded: Bool {
        if case .ended = sessionState { true } else { false }
    }
}
