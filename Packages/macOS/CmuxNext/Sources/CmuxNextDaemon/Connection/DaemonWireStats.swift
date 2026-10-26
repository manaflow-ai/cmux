import CmuxNextCompat

/// Counters of the app side of the daemon wire: bytes and lines each way, inbound lines by kind,
/// JSON decodes, terminal output bytes the app copied, and connections and bridge spawns by role.
/// `debug.daemon.wire` reports them; benches read them before and after a phase and subtract.
/// They are the baselines the p05-ipc program moves: one connection per app (095), one parse per
/// message (090) and zero copies of terminal output (113).
///
/// Every counter is one relaxed atomic add on a word allocated at init, so a reader thread records
/// without a lock and without an allocation. Chromium records the same way: lock-free counters in a
/// process-wide recorder (base/metrics/histogram_macros.h, base/metrics/statistics_recorder.h), and a
/// Mojo channel counts its own messages in place (mojo/core/channel.cc). ``process`` is that recorder,
/// the default every transport records into; tests pass their own instance.
public final class DaemonWireStats: Sendable {
    /// Why the app opened a daemon connection.
    public enum Role: Int, CaseIterable, Sendable {
        /// The app's control connection (`DaemonConnection`, role main).
        case control
        /// A page relay's connection (`DaemonConnection`, role page_relay).
        case pageRelay
        /// One attached terminal view (`TerminalAttachment`).
        case terminalAttach
        /// One attached agent session view (`AgentSessionAttachClient`).
        case agentSessionAttach
        /// A journal read (`SessionJournalRead`).
        case journalRead
        /// A loopback forward (`LoopbackForwardClient`).
        case loopbackForward
        /// Quit's close-every-workspace socket (`SessionEnding`).
        case sessionEnding
        /// `shutdown-daemon end_terminals` on its own socket.
        case shutdown
        /// A connect-and-close liveness probe (`DaemonSocketMemory`).
        case socketProbe
        /// A transport whose opener did not name a role.
        case unclassified

        /// The role's key in `debug.daemon.wire`.
        public var name: String {
            switch self {
            case .control: "control"
            case .pageRelay: "page_relay"
            case .terminalAttach: "terminal_attach"
            case .agentSessionAttach: "agent_session_attach"
            case .journalRead: "journal_read"
            case .loopbackForward: "loopback_forward"
            case .sessionEnding: "session_ending"
            case .shutdown: "shutdown"
            case .socketProbe: "socket_probe"
            case .unclassified: "unclassified"
            }
        }
    }

    /// What one inbound line was.
    public enum FrameKind: Int, CaseIterable, Sendable {
        /// A response to a request (`ok` or `id`).
        case reply
        /// A daemon event (`event`).
        case event
        /// A `cmux.protocol/2` `stream_item`.
        case streamItem
        /// A `cmux.protocol/2` `stream_end`.
        case streamEnd
        /// A line that did not decode as an envelope or matched nothing (dropped).
        case ignored

        /// The kind's key in `debug.daemon.wire`.
        public var name: String {
            switch self {
            case .reply: "reply"
            case .event: "event"
            case .streamItem: "stream_item"
            case .streamEnd: "stream_end"
            case .ignored: "ignored"
            }
        }
    }

    /// One read of every counter. The words are read one by one, so a snapshot taken while
    /// traffic flows may be a few counts apart between fields; a bench reads it at rest.
    public struct Snapshot: Sendable, Equatable {
        public var bytesRead: UInt64
        public var bytesWritten: UInt64
        public var linesRead: UInt64
        public var linesWritten: UInt64
        /// Inbound lines by kind; the kinds sum to `linesRead`.
        public var framesRead: [FrameKind: UInt64]
        /// Envelope decodes on the reader thread: one per inbound line.
        public var envelopeDecodes: UInt64
        /// Lines handed to a consumer that decodes them again (a reply's waiter, an event or stream
        /// handler): at least one more decode each.
        public var consumerDecodes: UInt64
        /// Terminal output bytes the app copied into a buffer of its own: the decode of each
        /// `output` line, and each merge of queued chunks into one.
        public var outputBytesCopiedApp: UInt64
        public var connectionsOpened: [Role: UInt64]
        public var connectionsClosed: [Role: UInt64]
        /// Connections opened through a ``DaemonBridge`` child process.
        public var bridgeSpawns: [Role: UInt64]

        public var connectionsOpenedTotal: UInt64 { connectionsOpened.values.reduce(0, &+) }
        public var bridgeSpawnsTotal: UInt64 { bridgeSpawns.values.reduce(0, &+) }
        /// Connections open now, per role.
        public var connectionsOpen: [Role: UInt64] {
            connectionsOpened.merging(connectionsClosed) { opened, closed in opened &- min(opened, closed) }
        }

        /// JSON decodes per inbound line, a lower bound (a consumer may decode a line more than
        /// once); 0 before the first line.
        public var decodesPerLine: Double {
            linesRead == 0 ? 0 : Double(envelopeDecodes &+ consumerDecodes) / Double(linesRead)
        }
    }

    /// The process-wide recorder every transport records into unless it is given another.
    public static let process = DaemonWireStats()

    private enum Counter: Int, CaseIterable {
        case bytesRead, bytesWritten, linesRead, linesWritten, envelopeDecodes, consumerDecodes, outputBytesCopiedApp
    }

    private static let frameBase = Counter.allCases.count
    private static let openedBase = frameBase + FrameKind.allCases.count
    private static let closedBase = openedBase + Role.allCases.count
    private static let bridgeBase = closedBase + Role.allCases.count
    private static let wordCount = bridgeBase + Role.allCases.count

    /// One counter (``Atomic`` cannot be an array element: it is not copyable).
    private final class Word: Sendable {
        let value = Atomic<UInt64>(0)
    }

    /// Every counter, laid out by the bases above; never resized.
    private let words: [Word]

    public init() {
        words = (0..<Self.wordCount).map { _ in Word() }
    }

    @inline(__always)
    private func add(_ index: Int, _ amount: UInt64) {
        guard let word = words[checked: index] else { return }
        word.value.add(amount, ordering: .relaxed)
    }

    @inline(__always)
    private func add(_ counter: Counter, _ amount: UInt64) { add(counter.rawValue, amount) }

    private func load(_ index: Int) -> UInt64 {
        guard let word = words[checked: index] else { return 0 }
        return word.value.load(ordering: .relaxed)
    }

    // MARK: Recording (any thread, lock-free)

    /// A connection to the daemon opened; `bridged` when a bridge child carries it.
    func connectionOpened(_ role: Role, bridged: Bool) {
        add(Self.openedBase + role.rawValue, 1)
        if bridged { add(Self.bridgeBase + role.rawValue, 1) }
    }

    /// A connection's descriptor closed (once per opened connection).
    func connectionClosed(_ role: Role) { add(Self.closedBase + role.rawValue, 1) }

    /// `count` bytes came off the socket in one read.
    func bytesRead(_ count: Int) { add(.bytesRead, UInt64(clamping: count)) }

    /// One line of `bytes` bytes (its newline included) was written.
    func lineWritten(bytes: Int) {
        add(.linesWritten, 1)
        add(.bytesWritten, UInt64(clamping: bytes))
    }

    /// One inbound line, its envelope decoded (or tried) once, routed as `kind`;
    /// `handedOff` when a consumer gets the line and decodes it again.
    func lineRead(_ kind: FrameKind, handedOff: Bool) {
        add(.linesRead, 1)
        add(.envelopeDecodes, 1)
        add(Self.frameBase + kind.rawValue, 1)
        if handedOff { add(.consumerDecodes, 1) }
    }

    /// The app copied `count` bytes of terminal output into a buffer of its own.
    func outputCopied(_ count: Int) {
        guard count > 0 else { return }
        add(.outputBytesCopiedApp, UInt64(clamping: count))
    }

    // MARK: Reading

    public func snapshot() -> Snapshot {
        func perRole(_ base: Int) -> [Role: UInt64] {
            Dictionary(uniqueKeysWithValues: Role.allCases.map { ($0, load(base + $0.rawValue)) })
        }
        return Snapshot(
            bytesRead: load(Counter.bytesRead.rawValue),
            bytesWritten: load(Counter.bytesWritten.rawValue),
            linesRead: load(Counter.linesRead.rawValue),
            linesWritten: load(Counter.linesWritten.rawValue),
            framesRead: Dictionary(uniqueKeysWithValues: FrameKind.allCases.map { ($0, load(Self.frameBase + $0.rawValue)) }),
            envelopeDecodes: load(Counter.envelopeDecodes.rawValue),
            consumerDecodes: load(Counter.consumerDecodes.rawValue),
            outputBytesCopiedApp: load(Counter.outputBytesCopiedApp.rawValue),
            connectionsOpened: perRole(Self.openedBase),
            connectionsClosed: perRole(Self.closedBase),
            bridgeSpawns: perRole(Self.bridgeBase))
    }

    /// Zeroes the traffic counters (bytes, lines, frames, decodes, copies). The connection counts
    /// stay, so open connections stay `opened - closed`. A count recorded during the reset may be
    /// lost; benches reset at rest.
    public func resetTraffic() {
        for word in words.prefix(Self.openedBase) { word.value.store(0, ordering: .relaxed) }
    }
}
