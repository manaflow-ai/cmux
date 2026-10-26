import CmuxNextCompat
public import CmuxNextTrace

/// Counters of the app side of the daemon wire: bytes and lines each way, inbound lines by kind,
/// JSON decodes of wire lines, terminal output bytes the app copied, and connections and bridge
/// spawns by role. `debug.daemon.wire` reports them; benches read them before and after a phase and
/// subtract. They are the baselines the p05-ipc program moves: one connection per app (095), one
/// parse per message (090) and zero copies of terminal output (113).
///
/// The app's composition root makes one in Debug and bench builds and puts it on the local daemon's
/// endpoints (``DaemonEndpoint/wireStats``), so every connection opened to that daemon counts into
/// it; a release build makes one only when the person opted in to field data
/// (``forBuild(fieldData:methods:)``), else none, and its transports record nothing. Each transport takes a
/// ``Recorder`` on one stripe of the counters (round robin), and every count is one relaxed atomic
/// add on a word of that stripe: a reader thread records with no lock and no allocation, and the
/// reader threads of different connections write different cache lines. A snapshot sums the
/// stripes. Chromium counts the same way: relaxed atomic counts in place, read by summing
/// (base/metrics/histogram_macros.h, base/metrics/persistent_sample_map.cc), and a Mojo channel
/// counts its own messages (mojo/core/channel.cc).
///
/// It also keeps the send-to-reply time of every request by method (``DaemonMethodLatency``, the
/// app end of the daemon's `server-stats` `ipc`): a transport stamps a request as it writes it and
/// records the time when the reader routes its reply.
public final class DaemonWireStats: Sendable {
    /// One daemon method a request can name: a v12 command or a `cmux.protocol/2` operation. The
    /// composition root lists them from the schema's method table.
    public struct Method: Sendable, Equatable {
        /// The name of the requests that count here, every `cmd` the table does not list.
        public static let otherName = "other"
        /// The schema's method id (`family << 8 | ordinal`, sdk-schema.json `method_id`); nil for
        /// ``otherName``. The daemon's `server-stats` `ipc_methods` rows carry the same id, so the
        /// two ends of one method join on it.
        public let id: UInt16?
        /// The request's `cmd` or v2 `operation`.
        public let name: String

        public init(id: UInt16?, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// One method's send-to-reply distribution, in microseconds. Percentiles are bucket upper
    /// bounds (``DaemonMethodLatency``). `count` includes the timed-out requests, each at its
    /// deadline; `abandoned` requests are in no percentile.
    public struct MethodLatency: Sendable, Equatable {
        public var method: String
        public var id: UInt16?
        public var count: UInt64
        public var p50Micros: UInt64
        public var p95Micros: UInt64
        public var p99Micros: UInt64
        public var maxMicros: UInt64
        /// Requests that got no reply within their deadline.
        public var timedOut: UInt64
        /// Requests whose connection closed before their reply.
        public var abandoned: UInt64
    }

    /// When a request was sent and the method it counts in; its reply records the time since.
    struct RequestStamp: Sendable {
        let slot: Int
        let sentNanos: UInt64
    }

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
            }
        }
    }

    /// What one inbound line was. Every line has exactly one kind, so the kinds sum to the lines read.
    public enum FrameKind: Int, CaseIterable, Sendable {
        /// A response a waiting request reads (`ok` or `id`).
        case reply
        /// A response nobody reads: no request waits for it (its deadline passed, or its id is
        /// unknown), or its request was sent without waiting and it is `ok:true`. Dropped.
        case droppedReply
        /// A daemon event (`event`).
        case event
        /// A `cmux.protocol/2` `stream_item`.
        case streamItem
        /// A `cmux.protocol/2` `stream_end`.
        case streamEnd
        /// A line that is not a JSON envelope, or one with no `event`, `type`, `id` or `ok`. Dropped.
        case ignored

        /// The kind's key in `debug.daemon.wire`.
        public var name: String {
            switch self {
            case .reply: "reply"
            case .droppedReply: "dropped_reply"
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
        /// JSON parses of inbound lines by the app, counted where they happen (``WireDecoder`` and
        /// the `JSONSerialization` reads of attach lines): the transport's envelope of a line its
        /// byte scan gives up or of an error reply, each reply type a waiter decodes, each payload
        /// type an event or stream line is decoded into. A line nobody reads adds none; a line
        /// decoded twice adds two.
        public var jsonDecodes: UInt64
        /// Terminal output bytes the app copied: each attach connection byte the transport's reader
        /// copies in and each line it copies out and into its Data, each `output` payload decoded out of its line
        /// (dropped ones too), and each merge of queued chunks into one.
        public var outputBytesCopiedApp: UInt64
        public var connectionsOpened: [Role: UInt64]
        public var connectionsClosed: [Role: UInt64]
        /// Connections opened through a ``DaemonBridge`` child process.
        public var bridgeSpawns: [Role: UInt64]
        /// Send-to-reply time of every method that got a reply, in table order.
        public var methods: [MethodLatency] = []

        public var connectionsOpenedTotal: UInt64 { connectionsOpened.values.reduce(0, &+) }
        public var bridgeSpawnsTotal: UInt64 { bridgeSpawns.values.reduce(0, &+) }
        /// Connections open now, per role.
        public var connectionsOpen: [Role: UInt64] {
            connectionsOpened.merging(connectionsClosed) { opened, closed in opened &- min(opened, closed) }
        }

        /// JSON decodes per inbound line; 0 before the first line.
        public var decodesPerLine: Double {
            linesRead == 0 ? 0 : Double(jsonDecodes) / Double(linesRead)
        }
    }

    /// Where one transport counts: a stripe of its recorder's words. Copies count into the same
    /// stripe.
    struct Recorder: Sendable {
        let stats: DaemonWireStats
        let stripe: Int

        /// A connection to the daemon opened; `bridged` when a bridge child carries it.
        func connectionOpened(_ role: Role, bridged: Bool) {
            stats.add(stripe, DaemonWireStats.openedBase + role.rawValue, 1)
            if bridged { stats.add(stripe, DaemonWireStats.bridgeBase + role.rawValue, 1) }
        }

        /// A connection's descriptor closed (once per opened connection).
        func connectionClosed(_ role: Role) { stats.add(stripe, DaemonWireStats.closedBase + role.rawValue, 1) }

        /// `count` bytes came off the socket in one read.
        func bytesRead(_ count: Int) { stats.add(stripe, Counter.bytesRead.rawValue, UInt64(clamping: count)) }

        /// One line of `bytes` bytes (its newline included) was written.
        func lineWritten(bytes: Int) {
            stats.add(stripe, Counter.linesWritten.rawValue, 1)
            stats.add(stripe, Counter.bytesWritten.rawValue, UInt64(clamping: bytes))
        }

        /// One inbound line was routed as `kind`.
        func lineRead(_ kind: FrameKind) {
            stats.add(stripe, Counter.linesRead.rawValue, 1)
            stats.add(stripe, DaemonWireStats.frameBase + kind.rawValue, 1)
        }

        /// The app parsed the JSON of one inbound line (or tried to) once.
        func decoded() { stats.add(stripe, Counter.jsonDecodes.rawValue, 1) }

        /// The app copied `count` bytes of terminal output into a buffer of its own.
        func outputCopied(_ count: Int) {
            guard count > 0 else { return }
            stats.add(stripe, Counter.outputBytesCopiedApp.rawValue, UInt64(clamping: count))
        }

        /// A request named `cmd` is being sent now.
        func requestSent(_ cmd: String) -> RequestStamp {
            RequestStamp(slot: stats.methodLatency.slot(of: cmd), sentNanos: stats.clock.nowNanos())
        }

        /// The reply of the request stamped `sent` was routed now.
        func replied(_ sent: RequestStamp) {
            stats.methodLatency.record(slot: sent.slot, micros: micros(since: sent))
        }

        /// The request stamped `sent` reached its deadline with no reply; a late reply is not timed.
        func timedOut(_ sent: RequestStamp) {
            stats.methodLatency.recordTimeout(slot: sent.slot, micros: micros(since: sent))
        }

        /// The connection of the request stamped `sent` closed before its reply.
        func abandoned(_ sent: RequestStamp) {
            stats.methodLatency.recordAbandoned(slot: sent.slot)
        }

        private func micros(since sent: RequestStamp) -> UInt64 {
            let now = stats.clock.nowNanos()
            return (now - min(sent.sentNanos, now)) / 1000
        }
    }

    private enum Counter: Int, CaseIterable {
        case bytesRead, bytesWritten, linesRead, linesWritten, jsonDecodes, outputBytesCopiedApp
    }

    private static let frameBase = Counter.allCases.count
    private static let openedBase = frameBase + FrameKind.allCases.count
    private static let closedBase = openedBase + Role.allCases.count
    private static let bridgeBase = closedBase + Role.allCases.count
    private static let wordCount = bridgeBase + Role.allCases.count
    /// Words in one 128-byte cache line (Apple silicon's line size).
    private static let lineWords = 128 / MemoryLayout<UInt64>.stride
    /// Words per stripe: every counter, rounded up to whole cache lines.
    private static let stripeWords = (wordCount + lineWords - 1) / lineWords * lineWords
    /// Stripes the transports spread over.
    static let stripeCount = 8

    /// `stripeCount` stripes of `stripeWords` words, 128-byte aligned; allocated once, never resized.
    nonisolated(unsafe) private let words: UnsafeMutablePointer<UInt64> // crash-allow: one fixed allocation; every access after init is an atomic operation (AtomicPointerSlot)
    /// The stripe the next transport gets.
    private let nextStripe = Atomic<UInt64>(0)
    /// Send-to-reply histograms by method.
    let methodLatency: DaemonMethodLatency
    /// Stamps requests and their replies.
    let clock: TraceClock

    /// The app's recorder: always in Debug and bench builds, where `debug.daemon.wire` reads it, and
    /// in a release build only when the person opted in to field data (the default-off feature
    /// `ipcMethodLatencyFieldData`); otherwise nil, and its transports record nothing.
    /// `methods` lists the daemon methods to time; it is not evaluated when there is no recorder.
    public static func forBuild(fieldData: Bool, methods: @autoclosure () -> [Method] = []) -> DaemonWireStats? {
        #if DEBUG || CMUX_BENCH_HOOKS
        DaemonWireStats(methods: methods())
        #else
        fieldData ? DaemonWireStats(methods: methods()) : nil
        #endif
    }

    /// - Parameters:
    ///   - methods: The methods whose replies are timed one by one; any other `cmd` counts as
    ///     ``Method/otherName``.
    ///   - clock: Stamps each request and its reply (tests inject one).
    public init(methods: [Method] = [], clock: TraceClock = TraceClock()) {
        methodLatency = DaemonMethodLatency(methods: methods)
        self.clock = clock
        let count = Self.stripeCount * Self.stripeWords
        // SAFETY: a fresh 128-byte aligned allocation of `count` words, every one initialized to zero here; it
        // is freed once, in deinit, and never resized.
        let raw = unsafe UnsafeMutableRawPointer.allocate(byteCount: count * MemoryLayout<UInt64>.stride, alignment: 128)
        words = unsafe raw.initializeMemory(as: UInt64.self, repeating: 0, count: count)
    }

    deinit {
        // SAFETY: the allocation of init, `stripeCount * stripeWords` initialized words; nothing else holds
        // `self` any more, so no slot is in use.
        unsafe words.deinitialize(count: Self.stripeCount * Self.stripeWords)
        unsafe UnsafeMutableRawPointer(words).deallocate()
    }

    /// The counter `index` of `stripe`. Every caller passes a stripe under ``stripeCount`` and an index under
    /// ``wordCount``, which is at most ``stripeWords``.
    @inline(__always)
    private func slot(_ stripe: Int, _ index: Int) -> AtomicPointerSlot {
        assert(stripe >= 0 && stripe < Self.stripeCount && index >= 0 && index < Self.stripeWords)
        // SAFETY: stripe * stripeWords + index is under stripeCount * stripeWords (the bounds above), so the
        // word is inside the allocation, which lives as long as `self`; it is 8-byte aligned (128-byte base).
        return unsafe AtomicPointerSlot(words + (stripe * Self.stripeWords + index))
    }

    /// A recorder for one new transport, on the next stripe.
    func recorder() -> Recorder {
        let next = nextStripe.add(1, ordering: .relaxed).oldValue
        return Recorder(stats: self, stripe: Int(truncatingIfNeeded: next % UInt64(truncatingIfNeeded: Self.stripeCount)))
    }

    @inline(__always)
    private func add(_ stripe: Int, _ index: Int, _ amount: UInt64) {
        slot(stripe, index).add(amount, ordering: .relaxed)
    }

    /// `index` summed over every stripe.
    private func load(_ index: Int) -> UInt64 {
        (0..<Self.stripeCount).reduce(0) { sum, stripe in
            sum &+ slot(stripe, index).load(ordering: .relaxed)
        }
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
            jsonDecodes: load(Counter.jsonDecodes.rawValue),
            outputBytesCopiedApp: load(Counter.outputBytesCopiedApp.rawValue),
            connectionsOpened: perRole(Self.openedBase),
            connectionsClosed: perRole(Self.closedBase),
            bridgeSpawns: perRole(Self.bridgeBase),
            methods: methodLatency.snapshot())
    }

    /// Zeroes the traffic counters (bytes, lines, frames, decodes, copies) of every stripe and the
    /// method histograms. The
    /// connection counts stay, so open connections stay `opened - closed`. A count recorded during
    /// the reset may be lost; benches reset at rest.
    public func resetTraffic() {
        for stripe in 0..<Self.stripeCount {
            for index in 0..<Self.openedBase {
                slot(stripe, index).store(0, ordering: .relaxed)
            }
        }
        methodLatency.reset()
    }
}
