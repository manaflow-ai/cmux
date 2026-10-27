// p07-memory.md section 3.C, task 020: frozen content whose memory grows is discarded, its opener
// group with it.

package import CmuxNextSettings

/// Discards a frozen page whose memory keeps growing, with the frozen hidden pages of its opener group.
///
/// Chrome's `FreezingPolicy` (components/performance_manager/freezing/freezing_policy.cc) discards
/// a frozen browsing instance whose private memory footprint grew by more than
/// `kFreezingMemoryGrowthThresholdToDiscardKb` since it froze, with
/// ``DiscardReason/frozenWithGrowingMemory``: a frozen page runs no script, so memory it still
/// takes is a leak the person cannot see. cmux keeps Chrome's reason and its group, but the
/// threshold is a cmux choice, not Chrome's constant: growth of at least
/// max(``minimumGrowthBytes``, ``growthShare`` of the bytes at freeze), so a large page needs to
/// grow in proportion.
///
/// A page's number is its share of the processes it runs in (``Reading``). It is the page's own
/// only while every page it shares them with is frozen too and the same as at the baseline: a
/// sharer that thaws, closes or goes moves the number with no growth in the page, so the page
/// takes a new baseline.
///
/// Chrome measures every `kCPUMeasurementInterval`. cmux does not sample on a period: each frozen
/// page has at most three one-shot readings, ``sampleDelays`` after it froze, and every reading the
/// hibernation takes anyway (memory pressure passes, the Task Manager) counts too. A growth is
/// reported once: its reading is the page's new baseline.
///
/// Chrome discards only frozen pages (the instance is frozen as one), so only members in ``pages``
/// go. The discard goes through ``ContentDiscardPlanner``: the lead rule (audio, capture, form
/// input, a download, a `beforeunload` that asks) and the person's own choices
/// (`browser.hibernation` off, a pinned tab, Never Hibernate This Site, open DevTools) keep a page
/// from this discard as from the timeout's, each member checked on its own.
///
/// ```swift
/// var growth = FrozenGrowthRule()
/// growth.froze("a", at: now, reading: .init(bytes: 100 << 20, sharers: ["a"]))
/// let growing = growth.record(["a": .init(bytes: 200 << 20, sharers: ["a"])])
/// let plan = growth.plan(growing: growing, groups: { [$0] }, candidates: hidden, setting: setting)
/// ```
package nonisolated struct FrozenGrowthRule: Sendable {
    /// One frozen page's readings.
    package nonisolated struct Page: Hashable, Sendable {
        /// When the page froze.
        package var frozenAt: ContinuousClock.Instant
        /// Its memory at freeze, else at its first reading after it, its last growth or its last
        /// sharer change; nil while a sharer is not frozen.
        package var baseline: UInt64?
        /// The pages it shared its processes with at ``baseline``, itself included.
        package var sharers: Set<String> = []
        /// The one-shot readings of ``sampleDelays`` already taken.
        package var wakeups = 0
    }

    /// One page's memory in one sample, and the pages it shares its processes with.
    package typealias Reading = PageMemoryReading

    /// Growth below this never discards, whatever the page's size (a cmux choice).
    package static let minimumGrowthBytes: UInt64 = 50 << 20
    /// The share of the memory at freeze a page must grow by when that is more than
    /// ``minimumGrowthBytes`` (a cmux choice).
    package static let growthShare = 0.25
    /// The one-shot readings after a page freezes: at most one wakeup each, three per frozen page.
    package static let sampleDelays: [Duration] = [.seconds(5 * 60), .seconds(30 * 60), .seconds(120 * 60)]

    /// The frozen pages, by key.
    package private(set) var pages: [String: Page] = [:]

    package init() {}

    /// The growth from `baseline` that discards: max(``minimumGrowthBytes``, ``growthShare`` of it).
    ///
    /// - Parameter baseline: The page's memory at freeze.
    package static func threshold(baseline: UInt64) -> UInt64 {
        max(minimumGrowthBytes, UInt64(Double(baseline) * growthShare))
    }

    /// Whether memory going from `baseline` to `current` is growth that discards.
    package static func grew(from baseline: UInt64, to current: UInt64) -> Bool {
        current > baseline && current - baseline >= threshold(baseline: baseline)
    }

    /// Page `key` froze at `instant`, with its `reading` when one is fresh: its baseline when every
    /// sharer is frozen; otherwise its first such reading after the freeze is.
    package mutating func froze(_ key: String, at instant: ContinuousClock.Instant, reading: Reading?) {
        pages[key] = Page(frozenAt: instant)
        if let reading { _ = take(reading, for: key) }
    }

    /// Page `key` thawed, hibernated or closed: its readings end.
    package mutating func thawed(_ key: String) {
        pages[key] = nil
    }

    /// Every page's readings end (`browser.hibernation` turned off).
    package mutating func removeAll() {
        pages.removeAll()
    }

    /// When the next one-shot reading is due, or nil when every frozen page had its three.
    package var nextWakeup: ContinuousClock.Instant? {
        pages.values.compactMap(Self.nextReading).min()
    }

    /// The one-shot reading due at `now` runs: every page whose next reading time passed counts it
    /// (one wakeup serves every page due by then).
    package mutating func wake(at now: ContinuousClock.Instant) {
        for (key, page) in pages {
            var page = page
            while let next = Self.nextReading(page), next <= now { page.wakeups += 1 }
            pages[key] = page
        }
    }

    /// Takes a reading of the pages' memory; returns the frozen pages that grew past their
    /// threshold, sorted. A page with no baseline, or whose sharers changed, takes this reading as
    /// its baseline; a page that grew takes it too, so its next report needs new growth.
    ///
    /// - Parameter readings: Each page's memory now; pages it does not name keep what they had.
    package mutating func record(_ readings: [String: Reading]) -> [String] {
        pages.keys.sorted().filter { key in readings[key].map { take($0, for: key) } ?? false }
    }

    /// Which hidden pages go for the growth of `growing`: the frozen members of each one's opener
    /// group, each checked for ``DiscardReason/frozenWithGrowingMemory`` on its own. A member that
    /// is not frozen stays, and so does one the probe kept lately
    /// (``ContentDiscardPlanner/Candidate/recentlyKept``): a reading does not ask it again.
    ///
    /// - Parameters:
    ///   - growing: The frozen pages that grew (``record(_:)``).
    ///   - groups: A page's opener group (its openers and the pages it opened), itself included.
    ///   - candidates: The hidden pages that could go, by key; members not in it (shown, closed,
    ///     already going) stay.
    ///   - setting: `browser.hibernation`.
    ///   - planner: The planner whose rules decide.
    /// - Returns: The members to discard, in order, and why each kept member stays.
    package func plan(growing: [String], groups: (String) -> Set<String>,
                      candidates: [String: ContentDiscardPlanner.Candidate], setting: BrowserHibernationSetting,
                      planner: ContentDiscardPlanner = ContentDiscardPlanner()) -> ContentDiscardPlanner.Plan {
        var plan = ContentDiscardPlanner.Plan()
        var seen: Set<String> = []
        for key in growing {
            for member in groups(key).union([key]).sorted() where seen.insert(member).inserted {
                guard pages[member] != nil, let candidate = candidates[member], !candidate.recentlyKept else { continue }
                if let kept = planner.eligibility(of: candidate, setting: setting, for: .frozenWithGrowingMemory).reason {
                    plan.exemptions[member] = kept
                } else {
                    plan.due.append(member)
                }
            }
        }
        return plan
    }

    /// `start`'s opener group: every page linked to it through `openers` (each page's opener), in
    /// either direction and transitively (its openers, the pages they opened, theirs), itself included.
    ///
    /// - Parameters:
    ///   - start: The page.
    ///   - openers: Each opened page's opener.
    package static func openerGroup<Node: Hashable>(of start: Node, openers: [Node: Node]) -> Set<Node> {
        var linked: [Node: [Node]] = [:]
        for (child, opener) in openers {
            linked[child, default: []].append(opener)
            linked[opener, default: []].append(child)
        }
        var group: Set<Node> = [start]
        var queue = [start]
        while let node = queue.popLast() {
            for next in linked[node] ?? [] where group.insert(next).inserted { queue.append(next) }
        }
        return group
    }

    /// Takes `reading` for frozen page `key`: true when it grew past its threshold.
    private mutating func take(_ reading: Reading, for key: String) -> Bool {
        guard var page = pages[key], reading.bytes > 0 else { return false }
        let sharers = reading.sharers.union([key])
        var grew = false
        if !sharers.allSatisfy({ pages[$0] != nil }) {
            // A sharer that runs script moves the shared number: none of that is this page's growth.
            page.baseline = nil
        } else if let baseline = page.baseline, page.sharers == sharers {
            grew = Self.grew(from: baseline, to: reading.bytes)
            if grew { page.baseline = reading.bytes }
        } else {
            page.baseline = reading.bytes
            page.sharers = sharers
        }
        pages[key] = page
        return grew
    }

    private static func nextReading(_ page: Page) -> ContinuousClock.Instant? {
        page.wakeups < sampleDelays.count ? page.frozenAt + sampleDelays[page.wakeups] : nil
    }
}
