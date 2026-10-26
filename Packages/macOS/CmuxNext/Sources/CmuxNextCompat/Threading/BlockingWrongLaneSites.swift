#if DEBUG || CMUX_BLOCKING_CHECKS
/// The call sites where a blocking seam ran in a job of a lane that must not block (``BlockingContext/cpuLane``),
/// with their counts: the ``BlockingKind/wrongLane`` part of ``BlockingViolationTable`` (Debug and bench builds).
///
/// Unlike the main-thread sites, these are recorded from any number of lane threads at once, so they live behind
/// one lock instead of the main thread's lock-free index. They are rare (each one is a bug to fix by moving the job
/// to `.files` or `.system`), the critical section is a scan of at most ``limit`` keys and an add, and the only
/// other taker is a `debug.blocking` read.
final class BlockingWrongLaneSites: Sendable {
    private struct Entry {
        var key: BlockingSiteKey
        var location: String
        var count: Int
    }

    private struct State {
        var entries: [Entry] = []
        var overflow = 0
    }

    /// The most wrong-lane sites one launch records; past it a new site only counts in ``overflow``.
    let limit: Int
    // concurrency-allow: a short non-blocking critical section (a bounded scan and an add, no I/O), taken by lane threads that are not async and by debug.blocking readers (lock carve-out).
    private let state = Mutex(State())

    init(limit: Int) {
        self.limit = limit
    }

    /// Counts one wrong-lane call at `fileID`:`line`; true when it is the site's first call (the caller reports it).
    func record(fileID: StaticString, line: UInt) -> Bool {
        let key = BlockingSiteKey(fileID: fileID, line: line)
        return state.withLock { state in
            if let index = state.entries.firstIndex(where: { $0.key == key }) {
                state.entries[index].count += 1
                return false
            }
            guard state.entries.count < limit else {
                state.overflow += 1
                return false
            }
            state.entries.append(Entry(key: key, location: "\(fileID):\(line)", count: 1))
            return true
        }
    }

    /// The sites in the order they first ran, with their counts.
    var sites: [BlockingSite] {
        state.withLock { state in
            state.entries.map { BlockingSite(kind: .wrongLane, location: $0.location, count: $0.count) }
        }
    }

    /// Calls not recorded because ``limit`` sites were already known.
    var overflow: Int { state.withLock { $0.overflow } }

    /// Zeroes every count; the sites stay known, so a site that runs again is counted, not reported again.
    func resetCounts() {
        state.withLock { state in
            for index in state.entries.indices { state.entries[index].count = 0 }
        }
    }
}
#endif
