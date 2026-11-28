import Foundation

/// Inputs to the pane state: transport facts and viewer choices.
public nonisolated enum RemotePaneEvent: Sendable, Hashable {
    case status(RemoteViewStatus)
    case frameShown
    case selectMode(RemoteControlMode)
    case controlAnyway
    /// The viewer pressed Stop; the transport closes the session.
    case stop
    /// A new session starts connecting: the pane's own retry of a lost path, or the viewer's
    /// Reconnect after an end someone chose.
    case reconnect
    /// Take over or Hand back: the live session ends and a new one starts in the requested
    /// mode (`cmux.rd/1` fixes a session's mode at its start), shown as reconnecting over
    /// the last frame.
    case restartForMode
    case setInteractiveMaxRtt(Int)
    /// The indicator's Stop (or the toolbar button of an active kind): the
    /// kind disappears at once; the transport revokes its consent.
    case stopUpstream(RemoteUpstreamKind)
    /// The tab hid or closed: every kind is revoked.
    case stopAllUpstreams
    /// The latency hold's flip came due with no new sample (``RemoteLatencyHold/due``).
    case latencyCheck
    /// A quiet reconnect's notice bound came due (``RemotePaneState/reconnectNoticeDelay``).
    case reconnectNoticeCheck
    /// A first connect's notice bound came due (``RemotePaneState/connectNoticeDelay``); the pane also sends it
    /// once at its start, which stamps when the connect began.
    case connectNoticeCheck
}

/// The pane's single writer. Pure: `reduce` maps a state, an event and the time it
/// happened to the next state, and the view renders whatever comes out.
public struct RemotePaneReducer {
    public nonisolated init() {}
    public nonisolated func reduce(_ state: RemotePaneState, _ event: RemotePaneEvent,
                                   now: ContinuousClock.Instant = .now) -> RemotePaneState {
        var next = reduceEvent(state, event)
        // A new session's path is not measured yet: nothing to hold.
        if next.status?.rttMs == nil { next.latency.reset() } else { next.latency.sample(over: next.sampleOverLimit, at: now) }
        // A reconnect over the last frame is silent until it has run for the notice bound.
        if next.reconnecting {
            let since = next.reconnectingSince ?? now
            next.reconnectingSince = since
            next.reconnectNoticeDue = now - since >= RemotePaneState.reconnectNoticeDelay
        } else {
            next.reconnectingSince = nil
            next.reconnectNoticeDue = false
        }
        // A first connect is silent for the short coming-up time; its card has Cancel once it shows.
        if next.comingUp {
            let since = next.connectingSince ?? now
            next.connectingSince = since
            next.connectNoticeDue = now - since >= RemotePaneState.connectNoticeDelay
        } else {
            next.connectingSince = nil
            next.connectNoticeDue = false
        }
        return next
    }

    private nonisolated func reduceEvent(_ state: RemotePaneState, _ event: RemotePaneEvent) -> RemotePaneState {
        var next = state
        switch event {
        case let .status(status):
            let wasEnded = if case .ended = state.sessionState { true } else { false }
            // A session that already ended (the person's Stop, the host's choice) keeps its reason:
            // its path closing afterwards says nothing new, and the card keeps that end's Reconnect.
            if wasEnded, case .ended(.connectionLost) = status.state { break }
            next.status = status
            if case .connecting = status.state, wasEnded {
                next.controlDespiteLatency = false
                next.reconnecting = state.hasFrame || state.reconnecting
                next.hasFrame = false
            }
        case .frameShown:
            if state.sessionState == .streaming {
                next.hasFrame = true
                next.reconnecting = false
            }
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
            // The new session has not ended: the old one's reason goes with it.
            status.endReason = nil
            next.status = status
            next.controlDespiteLatency = false
            next.reconnecting = state.hasFrame || state.reconnecting
            next.hasFrame = false
        case .restartForMode:
            guard !state.isEnded else { break }
            var status = state.status ?? RemoteViewStatus(state: .connecting)
            status.state = .connecting
            status.rttMs = nil
            next.status = status
            next.reconnecting = state.hasFrame || state.reconnecting
            next.hasFrame = false
        case let .setInteractiveMaxRtt(limit):
            next.interactiveMaxRttMs = max(0, limit)
        case let .stopUpstream(kind):
            next.status?.upstream.active.remove(kind)
            next.status?.upstream.requested.remove(kind)
        case .stopAllUpstreams:
            next.status?.upstream.active = []
            next.status?.upstream.requested = []
        case .latencyCheck, .reconnectNoticeCheck, .connectNoticeCheck:
            break
        }
        return next
    }
}

nonisolated extension RemotePaneState {
    public var isEnded: Bool {
        if case .ended = sessionState { true } else { false }
    }
}
