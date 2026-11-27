/// The host's bounds on what it holds for a page, and its drop episodes.
///
/// A page a full queue behind, or one that is held (nobody sees its pane, or it stopped draining:
/// ``PagePushLedger/stalled``), keeps what fits under the bound for its state, and the frames
/// ``PageStreamShedding`` allows are dropped past it. Everything else still queues up to the
/// ceiling. Once the page is caught up and not held, one `_acpmux/lagged` ends the episode.
public struct PageQueueBounds: Sendable, Equatable {
    public var maximumFrames: Int
    public var maximumBytes: Int
    /// The bound of a held page (smaller): what it misses it reads again once it drains.
    public var heldFrames: Int
    public var heldBytes: Int
    /// Past these even a reply no longer queues, and the connection closes.
    public var ceilingFrames: Int
    public var ceilingBytes: Int

    public init(maximumFrames: Int = 8192, maximumBytes: Int = 32 << 20, heldFrames: Int = 1024,
                heldBytes: Int = 1 << 20, ceilingFrames: Int = 32768, ceilingBytes: Int = 128 << 20) {
        self.maximumFrames = maximumFrames
        self.maximumBytes = maximumBytes
        self.heldFrames = heldFrames
        self.heldBytes = heldBytes
        self.ceilingFrames = ceilingFrames
        self.ceilingBytes = ceilingBytes
    }

    /// `frames` and `bytes` wait for the page; with `adding` more bytes, the queue is full.
    public func full(frames: Int, bytes: Int, adding: Int, held: Bool) -> Bool {
        let most = held ? min(heldFrames, maximumFrames) : maximumFrames
        let mostBytes = held ? min(heldBytes, maximumBytes) : maximumBytes
        return frames >= most || bytes + adding > mostBytes
    }

    public func pastCeiling(frames: Int, bytes: Int, adding: Int) -> Bool {
        frames >= ceilingFrames || bytes + adding > ceilingBytes
    }

    /// Caught up enough to end a drop episode: a quarter of the queue or less waits. A held page
    /// is never caught up: its episode ends once it drains, so it reads what it missed once.
    public func caughtUp(frames: Int, bytes: Int, held: Bool) -> Bool {
        !held && frames <= maximumFrames / 4 && bytes <= maximumBytes / 4
    }
}

/// One page's drop episode: frames dropped since it began, and whether its end is queued.
public struct PageShedEpisode: Sendable, Equatable {
    public enum Admission: Sendable, Equatable {
        /// Queue the frame for the page.
        case queue
        /// Drop it; `first`: it began an episode.
        case shed(first: Bool)
        /// Past the ceiling: close the connection.
        case overflow
    }

    /// What ends an episode: the count for its one `_acpmux/lagged`, and the kept transcript
    /// records that go right after it.
    public struct Ending: Sendable, Equatable {
        public var dropped: Int
        public var deferred: [String]

        public init(dropped: Int, deferred: [String]) {
            self.dropped = dropped
            self.deferred = deferred
        }
    }

    /// Frames dropped in the running episode; nil while none runs.
    public private(set) var dropped: Int?
    /// The episode's end is queued (its `_acpmux/lagged` follows the frames before it).
    public private(set) var ending = false
    /// Transcript records kept in the episode (a prompt, a permission ask), held until its
    /// `_acpmux/lagged`: the page reads what it missed from its last record before the marker
    /// (direct.ts `resyncAfterLag`), and a kept record with a later seq delivered before the marker
    /// would move that cursor past the hole, so the records the episode dropped were never read.
    public private(set) var deferred: [String] = []
    public private(set) var deferredBytes = 0

    public init() {}

    public var running: Bool { dropped != nil }

    /// Holds kept transcript record `text` until the episode's marker. False when none runs:
    /// the record goes to the page at once.
    public mutating func deferRecord(_ text: String, bytes: Int) -> Bool {
        guard dropped != nil else { return false }
        deferred.append(text)
        deferredBytes += bytes
        return true
    }

    /// What to do with an arriving frame. A frame that may be dropped is, while an episode runs
    /// or the queue is full; any other queues up to the ceiling.
    public mutating func admit(sheddable: Bool, full: Bool, pastCeiling: Bool) -> Admission {
        if sheddable, dropped != nil || full {
            let first = dropped == nil
            dropped = (dropped ?? 0) + 1
            return .shed(first: first)
        }
        return pastCeiling ? .overflow : .queue
    }

    /// True once: the episode runs, the page caught up, and its end is not queued yet.
    public mutating func beginEnding(caughtUp: Bool) -> Bool {
        guard dropped != nil, !ending, caughtUp else { return false }
        ending = true
        return true
    }

    /// Ends the episode: the count for its one `_acpmux/lagged` and the records that follow it, or
    /// nil when none ran.
    public mutating func end() -> Ending? {
        ending = false
        defer {
            dropped = nil
            deferred.removeAll()
            deferredBytes = 0
        }
        return dropped.map { Ending(dropped: $0, deferred: deferred) }
    }
}
