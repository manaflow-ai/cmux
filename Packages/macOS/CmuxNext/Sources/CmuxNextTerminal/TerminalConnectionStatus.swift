public import Foundation

/// Why a terminal view lost its stream, as its placeholder names it.
public nonisolated enum TerminalDisconnectCause: Sendable, Equatable {
    case streamEnded
    case connectionLost
    case attachFailed
    case fellBehind
    /// An administrator turned off the feature that reaches this terminal's
    /// machine (`DisabledFeatures`); the view does not reconnect.
    case turnedOffByOrganization
}

/// A terminal view's link to its terminal. A disconnected view keeps its
/// last screen and re-attaches, by itself for a while, then on the next event
/// (shown again, a key press, a click, focus or Retry); an exited one never does.
public nonisolated enum TerminalConnectionStatus: Sendable, Equatable {
    case connected
    /// A restored view has not shown its terminal yet (first attach or a
    /// retry after it failed).
    case restoring
    case disconnected(TerminalDisconnectCause, reconnecting: Bool)
    case exited

    /// Disconnected and not re-attaching by itself: only the person's next event (Retry, a key, a click, the
    /// view shown again) re-attaches it.
    public var waitsForThePerson: Bool {
        if case .disconnected(_, reconnecting: false) = self { return true }
        return false
    }
}

/// Why a dead terminal's host was lost when no exit status reached the
/// owner (tab `end.kind == host_lost`). The banner says "Terminal lost"
/// instead of "Process exited": the shell did not exit normally.
public nonisolated enum TerminalHostLoss: Sendable, Equatable {
    /// The host process ended (killed, crashed) before it reported an exit.
    case hostEnded
    /// A logout or session shutdown ended it.
    case sessionShutdown
    /// The owner no longer finds the host it recorded.
    case hostMissing
    /// The owner restarted the terminal after host losses until its restart
    /// budget ran out.
    case restartExhausted
    /// The owner's restart after a host loss failed.
    case restartFailed
}
