import QuartzCore

/// The animation components a row still runs, by row key. A layer that
/// shows a row adds that row's live components with their original begin
/// times, so recycled and newly visible rows join the motion in progress.
@MainActor
final class MotionLedger {
    enum Target: Hashable { case cell, content, typing, receiptOld, receiptNew }

    struct Entry {
        var id: Int
        var target: Target
        var keyPath: String
        var from: Double
        var to: Double
        var element: SpringElement
        var begin: CFTimeInterval
        var end: CFTimeInterval
        /// A non-spring hold (the row hidden while the send morph flies): this value until `end`.
        var hold: Double?
    }

    private(set) var entries: [String: [Entry]] = [:]
    private var serial = 0

    var isEmpty: Bool { entries.isEmpty }

    func add(_ key: String, _ target: Target, _ keyPath: String, from: Double, to: Double, _ element: SpringElement,
             begin: CFTimeInterval, hold: Double? = nil, until: CFTimeInterval? = nil) {
        serial += 1
        entries[key, default: []].append(Entry(id: serial, target: target, keyPath: keyPath, from: from, to: to, element: element,
                                               begin: begin, end: until ?? (begin + element.settleTime), hold: hold))
    }

    func live(_ key: String) -> [Entry] { entries[key] ?? [] }

    /// Drops entries that ended before `t` (layer time).
    func prune(before t: CFTimeInterval) {
        for (key, list) in entries {
            let keep = list.filter { $0.end > t }
            entries[key] = keep.isEmpty ? nil : keep
        }
    }

    /// The latest end of any entry (nil when empty).
    var lastEnd: CFTimeInterval? { entries.values.lazy.flatMap { $0 }.map(\.end).max() }
}
