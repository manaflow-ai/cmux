public import CmuxSafeConcurrency

/// A lock's place in cmux-next's lock order (CmuxSafeConcurrency.MutexRank): pass it to ``Mutex/init(_:rank:)``.
public typealias MutexRank = CmuxSafeConcurrency.MutexRank

/// cmux-next's lock order, outer first, in one table so the whole order reads in one place (as cmux-tui's
/// `LockRank` enum, cmux-tui/crates/cmux-tui-core/src/lock_rank.rs). A thread takes ranked mutexes in ascending
/// order; Debug builds stop the process on an inversion and name both locks (``MutexRank``). Chains that never
/// nest with each other get disjoint hundreds; a lock that takes no ranked lock while held is a leaf.
///
/// Ranked first: the Daemon, Terminal and CrashReporting locks (plans/cmux-next/chrome-parity/p10-stability.md,
/// task 148). A new rank goes here with the lock it is taken under or takes.
extension CmuxSafeConcurrency.MutexRank {
    // MARK: Daemon

    /// `LineTransport.socket`: writes and close are serialized under it, and `submit` and `sendLine` take
    /// ``daemonLineTransportState`` inside it so that send order equals wire order.
    public static let daemonLineTransportSocket = MutexRank("daemon.line-transport.socket", order: 100)
    /// `LineTransport.state`: the routing state. Its holder arms the deadline timer (an unranked lock).
    public static let daemonLineTransportState = MutexRank("daemon.line-transport.state", order: 110)
    /// `TerminalAttachment.control`: pushes a size state into ``daemonTerminalEventQueue`` under it, so that
    /// a newer generation never goes first.
    public static let daemonTerminalAttachmentControl = MutexRank("daemon.terminal-attachment.control", order: 200)
    /// `TerminalEventQueue.state`: resumes its consumer only after it is released.
    public static let daemonTerminalEventQueue = MutexRank("daemon.terminal-event-queue", order: 210)

    // MARK: Terminal

    /// `TerminalInputRing.backlog`: moving the ring to the backlog pops each ``terminalInputRingSlot`` under it.
    public static let terminalInputRingBacklog = MutexRank("terminal.input-ring.backlog", order: 300)
    /// A `TerminalInputRing` slot's record.
    public static let terminalInputRingSlot = MutexRank("terminal.input-ring.slot", order: 310)
    /// `TerminalInputLane.overflow`: one append or one swap of its array.
    public static let terminalInputLaneOverflow = MutexRank.leaf("terminal.input-lane.overflow")
    /// `TerminalOutputLane.backlog`: its waiters are resumed after it is released.
    public static let terminalOutputLaneBacklog = MutexRank.leaf("terminal.output-lane.backlog")

    // MARK: CrashReporting

    /// `CrashReporter.sentryHandlers`: the handlers are restored after it is released.
    public static let crashReporterSentryHandlers = MutexRank.leaf("crash-reporting.sentry-handlers")
    /// `LagSpikeReporter.limiter`.
    public static let lagSpikeLimiter = MutexRank.leaf("crash-reporting.lag-spike-limiter")
    /// `LagSpikeReporter.contextProvider`: the provider runs after it is released.
    public static let lagSpikeContextProvider = MutexRank.leaf("crash-reporting.lag-spike-context")
}
