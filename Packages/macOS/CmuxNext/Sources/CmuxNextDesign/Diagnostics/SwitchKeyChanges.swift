/// The key window changes of the cmux windows during a ``SwitchFrameTimer`` recording, counted per switch.
///
/// A Chromium page has its own child window, and it gets the keys only while that window is key. A switch between
/// two workspaces that each show a page moves the key window twice: the page that left gives it to the cmux window
/// (its window is ordered out), then the page that shows takes it after its first frame. Each change makes AppKit
/// tell every control of the cmux window. Chromium has all tabs in one window and changes no key window on a tab
/// switch, so the count per switch is the measure.
///
/// The marks are the bench spans `key.become` and `key.resign` (the cmux window's `becomeKey` and `resignKey`), the
/// ones `debug.new_tab`'s `bench_create` counts. A switch owns the marks from its intent to the next switch's
/// intent: the second change comes after the switch's own commit.
public nonisolated struct SwitchKeyChanges: Equatable, Sendable {
    /// One mark: a cmux window became key or resigned key.
    public nonisolated struct Mark: Equatable, Sendable {
        public var became: Bool
        /// Milliseconds since the recording started.
        public var at: Double

        public init(became: Bool, at: Double) {
            (self.became, self.at) = (became, at)
        }
    }

    public var marks: [Mark]
    /// The ring that recorded the marks filled: later marks are missing, so a count may be short.
    public var full: Bool

    public init(marks: [Mark], full: Bool = false) {
        (self.marks, self.full) = (marks, full)
    }

    /// The marks among a bench's spans (each: its name and its start in ms since the recording started, as the
    /// rows' `at_ms`); `full` when the spans filled their ring of `capacity`.
    public init(spans: [(name: String, start: Double)], capacity: Int) {
        marks = spans.compactMap { span in
            span.name == "key.become" || span.name == "key.resign" ? Mark(became: span.name == "key.become", at: span.start) : nil
        }
        full = spans.count >= capacity
    }

    /// The count columns of each row, given each row's `at_ms` in the rows' order (nil: a row with no place gets
    /// no column). A row owns the marks from its `at_ms` up to the next placed row's `at_ms`; the last row owns the
    /// rest, and a mark before the first row is no row's. `key_changes` is `key_become` plus `key_resign`;
    /// `key_marks_full` is 1 when ``full``.
    public func columns(forRowsAt starts: [Double?]) -> [[String: Double]] {
        let placed = starts.compactMap { $0 }.sorted()
        return starts.map { start in
            guard let start else { return [:] }
            let end = placed.first { $0 > start } ?? .infinity
            let own = marks.filter { $0.at >= start && $0.at < end }
            let become = Double(own.count(where: \.became))
            return ["key_changes": Double(own.count), "key_become": become, "key_resign": Double(own.count) - become,
                    "key_marks_full": full ? 1 : 0]
        }
    }

    /// `rows` with the count columns of each row that has `at_ms`; a row's own column of the same name stays.
    public func counted(_ rows: [[String: Double]]) -> [[String: Double]] {
        zip(rows, columns(forRowsAt: rows.map { $0["at_ms"] })).map { row, counts in row.merging(counts) { own, _ in own } }
    }
}
