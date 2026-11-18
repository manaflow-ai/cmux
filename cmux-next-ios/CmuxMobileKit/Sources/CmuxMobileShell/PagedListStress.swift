#if DEBUG && os(iOS)
import CmuxMobileDesign
import Foundation

/// A load the stress bench puts on a list while someone scrolls it (verify/paged-list.md, "Stress
/// bench"): rows arriving at the newest end, edits at the head, middle and tail of what was served
/// (some change a row's height), rows inserted in the middle, removals, moves, bursts of edits in one
/// tick, page latency with jitter, failing pages, repeated ids and rows taller than the screen.
/// Seeded, so a run repeats.
struct PagedStressLoad: Sendable {
    var newestPerSecond: Double
    var updatesPerSecond: Double
    var insertsPerSecond: Double
    var removesPerSecond: Double
    var movesPerSecond: Double
    /// Every 2 s, this many edits in one tick.
    var burst: Int
    var latency: ClosedRange<Double>
    /// Every Nth page read fails once (0: none).
    var failEvery: Int
    /// Rows a page holds, and the rows the source has in all.
    var pageSize = 30
    var total = 6000
    /// Each tick (20 a second) the main thread is kept busy this long (a busy app).
    var busyMs = 0.0

    static let named: [String: PagedStressLoad] = [
        "calm": PagedStressLoad(newestPerSecond: 0, updatesPerSecond: 0, insertsPerSecond: 0, removesPerSecond: 0,
                                movesPerSecond: 0, burst: 0, latency: 0.2...0.4, failEvery: 0),
        "flood": PagedStressLoad(newestPerSecond: 40, updatesPerSecond: 120, insertsPerSecond: 20, removesPerSecond: 6,
                                 movesPerSecond: 6, burst: 1000, latency: 0.05...0.8, failEvery: 9),
        "edits": PagedStressLoad(newestPerSecond: 2, updatesPerSecond: 300, insertsPerSecond: 0, removesPerSecond: 0,
                                 movesPerSecond: 0, burst: 2000, latency: 0.2...0.4, failEvery: 0),
        "inserts": PagedStressLoad(newestPerSecond: 10, updatesPerSecond: 10, insertsPerSecond: 80, removesPerSecond: 20,
                                   movesPerSecond: 20, burst: 0, latency: 0.2...0.4, failEvery: 0),
        // 100,000 rows in pages of 200, read fast, with a steady trickle of every change: the list a
        // bounded window (`-cmux-mobile-paged-lab-window`) keeps to a few hundred rows in memory.
        "huge": PagedStressLoad(newestPerSecond: 10, updatesPerSecond: 60, insertsPerSecond: 10, removesPerSecond: 5,
                                movesPerSecond: 5, burst: 1000, latency: 0.02...0.05, failEvery: 0, pageSize: 200, total: 100_000),
        // The flood with the main thread kept busy 4 ms of every 50 (an app doing other work).
        "busy": PagedStressLoad(newestPerSecond: 40, updatesPerSecond: 120, insertsPerSecond: 20, removesPerSecond: 6,
                                movesPerSecond: 6, burst: 1000, latency: 0.05...0.8, failEvery: 9, busyMs: 4),
    ]
}

/// The bench's ``PagedListSource``: pages of lab rows (the load's page size and total) and, once
/// started, a stream of changes at the load's rates.
@MainActor
final class PagedStressSource: PagedListSource {
    typealias Item = PagedLabItem

    let load: PagedStressLoad
    private var rng: SplitMix
    /// Ids served, newest first: where edits, inserts, removals and moves land.
    private var served: [Int] = []
    private var servedSet: Set<Int> = []
    private var reads = 0
    private var nextLive = -1
    private var nextInserted = 1_000_000
    private var edits = 0
    private var continuation: AsyncStream<[PagedListChange<PagedLabItem>]>.Continuation?
    private var ticking: Task<Void, Never>?

    init(load: PagedStressLoad, seed: UInt64 = 7) {
        self.load = load
        rng = SplitMix(seed: seed)
    }

    func page(after cursor: String?) async throws -> PagedListPage<PagedLabItem> {
        reads += 1
        let failing = load.failEvery > 0 && reads % load.failEvery == 0
        // motion: not an animation; the bench's source answers after a network-like, jittered delay.
        try await Task.sleep(for: .seconds(Double.random(in: load.latency, using: &rng)))
        if failing { throw PagedLabSource.Failure() }
        let start = cursor.flatMap(Int.init) ?? 0
        let end = min(load.total, start + load.pageSize)
        var ids = Array(start..<max(start, end))
        // A source that repeats a row of the page before: shown once.
        if start > 0, ids.count > 3 { ids.insert(start - 1, at: 3) }
        if cursor == nil {
            served = []
            servedSet = []
        }
        for id in ids where servedSet.insert(id).inserted { served.append(id) }
        let items = ids.map(Self.item)
        return PagedListPage(items: items, nextCursor: end < load.total ? String(end) : nil)
    }

    func changes() -> AsyncStream<[PagedListChange<PagedLabItem>]> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.ticking = Task { [weak self] in await self?.tick() }
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.ticking?.cancel() } }
        }
    }

    /// One row; every 25th is taller than the screen.
    static func item(_ id: Int) -> PagedLabItem {
        id > 0 && id % 25 == 0 ? PagedLabItem(id: id, text: Array(repeating: "a row taller than the screen", count: 40).joined(separator: " ")) : PagedLabItem(id: id)
    }

    private func tick() async {
        let step = 0.05
        var owed = [Double](repeating: 0, count: 5)
        var sinceBurst = 0.0
        while !Task.isCancelled {
            // motion: not an animation; the load's clock (20 ticks a second).
            try? await Task.sleep(for: .seconds(step))
            guard served.count > 40 else { continue }
            let rates = [load.newestPerSecond, load.updatesPerSecond, load.insertsPerSecond, load.removesPerSecond, load.movesPerSecond]
            var batch: [PagedListChange<PagedLabItem>] = []
            for kind in 0..<5 {
                owed[kind] += rates[kind] * step
                while owed[kind] >= 1 {
                    owed[kind] -= 1
                    if let change = make(kind) { batch.append(change) }
                }
            }
            sinceBurst += step
            if load.burst > 0, sinceBurst >= 2 {
                sinceBurst = 0
                batch.append(.update((0..<load.burst).map { _ in edited(pick()) }))
            }
            if !batch.isEmpty { continuation?.yield(batch) }
            if load.busyMs > 0 {
                // A busy main thread: the work an app does beside the list.
                let until = CFAbsoluteTimeGetCurrent() + load.busyMs / 1000
                while CFAbsoluteTimeGetCurrent() < until {}
            }
        }
    }

    /// A served row in the head, middle or tail (a third each).
    private func pick() -> Int {
        let n = served.count
        let region = Int.random(in: 0..<3, using: &rng)
        let range: Range<Int> = switch region {
        case 0: 0..<max(1, n / 10)
        case 1: (n * 4 / 10)..<max(n * 4 / 10 + 1, n * 6 / 10)
        default: (n * 9 / 10)..<n
        }
        return served[Int.random(in: range, using: &rng)]
    }

    /// A new value for `id`; every other edit changes its height.
    private func edited(_ id: Int) -> PagedLabItem {
        edits += 1
        let base = Self.item(id)
        return edits % 2 == 0 ? PagedLabItem(id: id, mine: base.mine, text: base.text + " (edited \(edits), now a line or two longer than it was)")
            : PagedLabItem(id: id, mine: base.mine, text: base.text + " (edited \(edits))")
    }

    private func make(_ kind: Int) -> PagedListChange<PagedLabItem>? {
        switch kind {
        case 0:
            nextLive -= 1
            served.insert(nextLive, at: 0)
            servedSet.insert(nextLive)
            return .newest([PagedLabItem(id: nextLive)])
        case 1:
            return .update([edited(pick())])
        case 2:
            let after = pick()
            nextInserted += 1
            if let at = served.firstIndex(of: after) {
                served.insert(nextInserted, at: at + 1)
                servedSet.insert(nextInserted)
            }
            return .insert([PagedLabItem(id: nextInserted)], after: after)
        case 3:
            let id = pick()
            if let at = served.firstIndex(of: id) { served.remove(at: at) }
            servedSet.remove(id)
            return .remove([id])
        default:
            let id = pick()
            let after = pick()
            guard id != after, let from = served.firstIndex(of: id) else { return nil }
            served.remove(at: from)
            if let at = served.firstIndex(of: after) { served.insert(id, at: at + 1) }
            return .move(id, after: after)
        }
    }
}

/// A small seeded generator (SplitMix64), so a stress run repeats.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
