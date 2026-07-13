nonisolated enum TerminalNotificationScrollRestorePhase: Equatable {
    case idle
    case sessionScrollbackReplayActive(SessionScrollbackReplayCompletionMarker)
    case sessionScrollbackReplayCompleted
    case pending(
        TerminalNotificationScrollPosition,
        sessionScrollbackReplayCompletionMarker: SessionScrollbackReplayCompletionMarker?
    )

    var sessionScrollbackReplayCompletionMarker: SessionScrollbackReplayCompletionMarker? {
        switch self {
        case .idle, .sessionScrollbackReplayCompleted:
            return nil
        case .sessionScrollbackReplayActive(let marker):
            return marker
        case .pending(_, let marker):
            return marker
        }
    }
}
