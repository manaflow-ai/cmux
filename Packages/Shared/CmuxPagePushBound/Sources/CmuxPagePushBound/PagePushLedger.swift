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
    }

    /// The ack deadline passed with no ack. True: the next push may go, as before. False: the
    /// unacked pushes are full, so the host holds until the page answers (``stalled``); the first
    /// such deadline counts one stall.
    public mutating func deadlinePassed() -> Bool {
        guard full else { return true }
        if !stalled {
            stalled = true
            stalls += 1
        }
        return false
    }

    /// The page acked push `seq`. Pushes ack in order, so it and every one before it are applied.
    /// True when this ended a stall: the page runs again, and the held push's completion runs.
    @discardableResult
    public mutating func acked(seq: Int) -> Bool {
        if let last = unacked.lastIndex(where: { $0.seq <= seq }) {
            for push in unacked[...last] { unackedBytes -= push.bytes }
            unacked.removeFirst(last + 1)
        }
        return resume()
    }

    /// The page sent something: its script runs, so it drains again, though no ack came (an
    /// older page that never acks). True when this ended a stall.
    @discardableResult
    public mutating func pageAnswered() -> Bool { resume() }

    /// A new connection: nothing is unacked and nothing is held.
    public mutating func reset() {
        unacked.removeAll()
        unackedBytes = 0
        stalled = false
    }

    private mutating func resume() -> Bool {
        guard stalled else { return false }
        stalled = false
        unacked.removeAll()
        unackedBytes = 0
        return true
    }
}
