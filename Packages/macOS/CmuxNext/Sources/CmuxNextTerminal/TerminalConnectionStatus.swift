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
/// last screen and re-attaches on the next event (shown again, a key press,
/// a click or focus); an exited one never does.
public nonisolated enum TerminalConnectionStatus: Sendable, Equatable {
    case connected
    case disconnected(TerminalDisconnectCause, reconnecting: Bool)
    case exited
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
}

/// What a lost host left as evidence (tab `end.cause`, cx-0tgl): the first
/// signal it recorded and who sent it, and whether it had panicked. The
/// banner names it after the reason, in localized words.
public nonisolated struct TerminalHostLossCause: Sendable, Equatable {
    /// Conventional signal name (`SIGTERM`).
    public var signal: String?
    public var senderPid: Int64?
    /// The sender's process name, when it still ran when recorded.
    public var senderName: String?
    public var panicked: Bool

    public init(signal: String? = nil, senderPid: Int64? = nil, senderName: String? = nil,
                panicked: Bool = false) {
        self.signal = signal
        self.senderPid = senderPid
        self.senderName = senderName
        self.panicked = panicked
    }
}
