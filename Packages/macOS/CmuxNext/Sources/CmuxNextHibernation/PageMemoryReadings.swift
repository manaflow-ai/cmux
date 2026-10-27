// p07-memory.md section 3.C, task 020: the memory readings the browser hibernation ranks
// discards by and the frozen pages' growth is measured from.

/// One page's memory in one sample: its share of its own processes, and the pages it shares them
/// with (the resource sampler's `TabMemoryReading`, `ResourceSampleSet.tabMemoryReadings`).
package nonisolated struct PageMemoryReading: Hashable, Sendable {
    package var bytes: UInt64
    /// The pages that run in at least one of its processes, itself included. Its number is a share
    /// of those processes, so it moves when one of these pages comes, goes or grows.
    package var sharers: Set<String>

    package init(bytes: UInt64, sharers: Set<String>) {
        self.bytes = bytes
        self.sharers = sharers
    }
}

/// The pages' last memory readings, from the hibernation's own samples and the Task Manager's
/// (which take the same estimate). Only its methods change it: a sample replaces every reading,
/// another sampler's readings change only the live pages it measured.
///
/// ```swift
/// var readings = PageMemoryReadings()
/// guard readings.begin() else { return }  // one sample at a time
/// readings.land(await measure(), at: .now)
/// ```
package nonisolated struct PageMemoryReadings: Sendable {
    /// Each page's last number; a page with nothing measured keeps what it had.
    package private(set) var bytes: [String: UInt64] = [:]
    /// The pages each page's last number was shared with, itself included.
    package private(set) var sharers: [String: Set<String>] = [:]
    /// When the last reading landed.
    package private(set) var measuredAt: ContinuousClock.Instant?
    /// A sample runs now: the next one waits for its answer.
    package private(set) var isMeasuring = false
    /// A reading this recent counts as now.
    package static let maxAge: Duration = .seconds(30)

    package init() {}

    /// Whether the last reading counts as now.
    package func isFresh(at now: ContinuousClock.Instant) -> Bool {
        measuredAt.map { now - $0 < Self.maxAge } ?? false
    }

    /// Page `key`'s last reading, nil when none measured anything.
    package func reading(_ key: String) -> PageMemoryReading? {
        guard let value = bytes[key], value > 0 else { return nil }
        return PageMemoryReading(bytes: value, sharers: sharers[key] ?? [key])
    }

    /// A sample starts; false while one runs (its answer serves this caller too).
    package mutating func begin() -> Bool {
        guard !isMeasuring else { return false }
        isMeasuring = true
        return true
    }

    /// The sample `begin()` started landed: it replaces every reading.
    package mutating func land(_ sample: [String: PageMemoryReading], at now: ContinuousClock.Instant) {
        isMeasuring = false
        bytes = sample.mapValues(\.bytes)
        sharers = sample.mapValues(\.sharers)
        measuredAt = now
    }

    /// Another sampler's readings: only the pages `live` names with something measured change.
    package mutating func note(_ sample: [String: PageMemoryReading], at now: ContinuousClock.Instant, live: (String) -> Bool) {
        for (key, reading) in sample where reading.bytes > 0 && live(key) {
            bytes[key] = reading.bytes
            sharers[key] = reading.sharers
        }
        measuredAt = now
    }

    /// Page `key` closed.
    package mutating func forget(_ key: String) {
        bytes[key] = nil
        sharers[key] = nil
    }
}
