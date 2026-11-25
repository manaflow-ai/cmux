/// The pushes a page has not acked, and whether the host stopped pushing it.
///
/// The host pushes a page its stream and waits for the page's ack of each push, or a deadline. A
/// page whose main thread is stuck acks nothing, and every push that went on the deadline waited in
/// its renderer, unread: on Leo's NIGHTLY 9d514c685e48 a chat page spinning in a script grew its
/// renderer to 14 GB. Past ``Bounds/maximumUnackedBytes`` or ``Bounds/maximumUnackedPushes`` the
/// ledger says to hold: no push goes until the page answers (an ack of any push, or a send).
public struct PagePushLedger: Sendable {
    public struct Bounds: Sendable, Equatable {
        public var maximumUnackedBytes: Int
        public var maximumUnackedPushes: Int

        public init(maximumUnackedBytes: Int = 8 << 20, maximumUnackedPushes: Int = 240) {
            self.maximumUnackedBytes = maximumUnackedBytes
            self.maximumUnackedPushes = maximumUnackedPushes
        }
    }

    /// One push the page has not acked: its seq and frame bytes.
    public struct Push: Sendable, Equatable {
        public var seq: Int
        public var bytes: Int
        public init(seq: Int, bytes: Int) {
            self.seq = seq
            self.bytes = bytes
        }
    }

    public let bounds: Bounds
    /// Oldest first; at most ``Bounds/maximumUnackedPushes`` long, since the host stops there.
    public private(set) var unacked: [Push] = []
    public private(set) var unackedBytes = 0
    /// The host holds its pushes until the page answers.
    public private(set) var stalled = false
    /// Times the host stopped pushing (tests, the bench).
    public private(set) var stalls = 0
    /// The newest seq the host pushed on this connection; an ack past it names a push never made.
    public private(set) var newestPushed: Int?
    /// Acks past ``newestPushed`` that were ignored (tests, the bench).
    public private(set) var acksPastNewest = 0
    /// One ignored ack was already reported since the last stall began (or the connection opened).
    private var reportedPastNewest = false

    /// What an ack did.
    public enum Ack: Sendable, Equatable {
        /// The acked push and every one before it are applied; the host was not holding.
        case applied
        /// It ended a stall: the page runs again, and the held push's completion runs.
        case resumed
        /// Its seq is past ``PagePushLedger/newestPushed``: nothing changed and nothing resumes.
        /// `report` is true once per stall episode, so a misbehaving page shows in the log
        /// without flooding it.
        case pastNewestPush(newest: Int?, report: Bool)
    }

    public init(bounds: Bounds = Bounds()) {
        self.bounds = bounds
    }

    /// Whether the unacked pushes reach either bound.
    public var full: Bool {
        unackedBytes >= bounds.maximumUnackedBytes || unacked.count >= bounds.maximumUnackedPushes
    }

    /// The host pushed `seq` with `bytes` of frames and waits for its ack.
    public mutating func pushed(seq: Int, bytes: Int) {
        unacked.append(Push(seq: seq, bytes: bytes))
        unackedBytes += bytes
        newestPushed = max(newestPushed ?? seq, seq)
    }

    /// The ack deadline passed with no ack. True: the next push may go, as before. False: the
    /// unacked pushes are full, so the host holds until the page answers (``stalled``); the first
    /// such deadline counts one stall.
    public mutating func deadlinePassed() -> Bool {
        guard full else { return true }
        if !stalled {
            stalled = true
            stalls += 1
            reportedPastNewest = false
        }
        return false
    }

    /// The page acked push `seq`. Pushes ack in order, so it and every one before it are applied.
    /// An ack past ``newestPushed`` names a push the host never made: a buggy page. It changes
    /// nothing and ends no stall, else such a page would walk past the bound (``Ack/pastNewestPush``).
    public mutating func ack(seq: Int) -> Ack {
        guard let newest = newestPushed, seq <= newest else {
            acksPastNewest += 1
            let report = !reportedPastNewest
            reportedPastNewest = true
            return .pastNewestPush(newest: newestPushed, report: report)
        }
        if let last = unacked.lastIndex(where: { $0.seq <= seq }) {
            for push in unacked[...last] { unackedBytes -= push.bytes }
            unacked.removeFirst(last + 1)
        }
        return resume() ? .resumed : .applied
    }

    /// ``ack(seq:)``, true when it ended a stall.
    @discardableResult
    public mutating func acked(seq: Int) -> Bool { ack(seq: seq) == .resumed }

    /// The page sent something: its script runs, so it drains again, though no ack came (an
    /// older page that never acks). True when this ended a stall.
    @discardableResult
    public mutating func pageAnswered() -> Bool { resume() }

    /// A new connection: nothing is unacked and nothing is held.
    public mutating func reset() {
        unacked.removeAll()
        unackedBytes = 0
        stalled = false
        newestPushed = nil
        reportedPastNewest = false
    }

    private mutating func resume() -> Bool {
        guard stalled else { return false }
        stalled = false
        unacked.removeAll()
        unackedBytes = 0
        return true
    }
}
