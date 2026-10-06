public import CmuxNextDaemon
public import Foundation

// The machine's nested types: attach attempts, phases, events and effects.
extension TerminalAttachMachine {
    /// An attach in flight: `link` is nil until the open completes, then the
    /// machine waits for that link's replay.
    public nonisolated struct Pending: Hashable, Sendable {
        /// Unique per open, so a late completion never matches a newer one.
        public var attempt: Int
        /// Consecutive attaches that have not reached `live`, this one included.
        public var failures: Int
        public var size: CellSize
        public var link: Link?
        /// Failed re-attaches before this attempt when it is a re-attach of
        /// a disconnected view; nil for the first attach and overflow.
        public var reconnects: Int?

        public init(attempt: Int, failures: Int, size: CellSize, link: Link?, reconnects: Int? = nil) {
            self.attempt = attempt
            self.failures = failures
            self.size = size
            self.link = link
            self.reconnects = reconnects
        }
    }

    public typealias DisconnectReason = TerminalDisconnectReason
    public typealias LinkStatus = TerminalLinkStatus

    public nonisolated struct Disconnected: Hashable, Sendable {
        public var reason: DisconnectReason
        /// Re-attaches that failed since the view disconnected.
        public var failedReconnects: Int
    }

    public nonisolated enum Phase: Hashable, Sendable {
        case detached
        case attaching(Pending)
        case live(Link)
        case reattaching(Pending)
        case disconnected(Disconnected)
        /// The terminal's process ended: the last screen stays, no re-attach.
        case exited
        case closed
    }

    public nonisolated enum Event: Hashable, Sendable {
        case start
        /// The open for `attempt` returned `link`.
        case opened(Link, attempt: Int)
        /// The open for `attempt` failed.
        case openFailed(attempt: Int)
        /// `link`'s replay reached the consumer.
        case replayDelivered(Link)
        /// Encoded user input from the surface.
        case input(Data)
        /// The view's settled grid.
        case resize(CellSize)
        /// The surface started or stopped rendering (SurfaceLedger).
        case visibility(Bool)
        /// The surface gained keyboard focus.
        case focused
        /// `link`'s stream announced the PTY grid (a daemon `resized`).
        case gridAnnounced(Link, CellSize)
        /// `link`'s stream ended.
        case ended(Link, TerminalChannelCloseReason)
        /// The terminal or the daemon connection is back (App observation):
        /// a disconnected view re-attaches.
        case reconnect
        /// The daemon reports the terminal's process ended.
        case processExited
        /// The daemon reports the terminal running again after it reported it
        /// dead (a transient report while its host was re-adopted, or a
        /// restart in place). An exited view re-attaches.
        case processRevived
        /// The tab closed or the view was dropped.
        case close
    }

    public nonisolated enum Effect: Hashable, Sendable {
        /// Open a new attachment at `size`; report `.opened` or `.openFailed`.
        /// An open is never abandoned mid-handshake: when the machine moved
        /// on, the link it returns is detached at once, with its lease, so
        /// the daemon frees the view attachment explicitly.
        case open(attempt: Int, size: CellSize)
        /// Like `open`, after the capped backoff for `failedReconnects`
        /// failed re-attaches in a row.
        case openAfterBackoff(attempt: Int, size: CellSize, failedReconnects: Int)
        case send(Link, Data)
        /// Report `size` on `link`, then claim canonical geometry.
        case claim(Link, CellSize)
        case release(Link)
        case detach(Link)
        /// Show `LinkStatus` in the view.
        case status(LinkStatus)
        /// End the consumer's stream.
        case finish
    }
}
