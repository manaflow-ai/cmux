public import Foundation

/// Why a terminal view lost its stream, as its placeholder names it.
public nonisolated enum TerminalDisconnectCause: Sendable, Equatable {
    case streamEnded
    case connectionLost
    case attachFailed
    case fellBehind
}

/// A terminal view's link to its terminal. A disconnected view keeps its
/// last screen and re-attaches on the next event (shown again, a key press,
/// a click or focus); an exited one never does.
public nonisolated enum TerminalConnectionStatus: Sendable, Equatable {
    case connected
    case disconnected(TerminalDisconnectCause, reconnecting: Bool)
    case exited
}
