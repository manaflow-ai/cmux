import CmuxNextCompat
import Foundation

/// The measured stage of every wait that keeps what the person switched to, typed or asked for off the screen
/// (hold-class.md rule 1, audit B): a paint hold over a tab or a workspace that has not painted, a held terminal
/// frame, a first-tab hold. Each such wait has a written reason, a hard limit, and a row here: how many holds ran,
/// how each ended, and how long the longest held, so a bench or an agent sees a hold that grows (`debug.input`
/// section `holds`).
///
/// One record per ended hold, under a lock (no allocation once an owner has its row): the owner keeps its own begin
/// instant and records the hold's length when it ends. The app's one ledger is its deadline scheduler's
/// (``MainDeadlineScheduler/holds``): every such hold's limit is a ``MainDeadline`` placed there.
///
/// ```swift
/// let began = VisibleHolds.now()
/// // ... the hold ends:
/// deadlines.holds.record(owner: "pane.paint-hold", reason: "unpainted page", limit: .milliseconds(33),
///                        began: began, end: .shown)
/// ```
public nonisolated final class VisibleHolds: Sendable {
    /// How a hold ended.
    public enum End: String, Sendable, CaseIterable, Codable {
        /// What it waited for showed (the page painted, the terminal drew its content).
        case shown
        /// Its hard limit passed first.
        case limit
        /// The person's input (a key, a click) ended it before the input was delivered.
        case input
        /// A newer hold or a teardown took its place.
        case replaced
    }

    /// One owner's holds since launch or the last ``reset()``.
    public struct Row: Sendable, Equatable, Codable {
        /// The hold's owner (`pane.paint-hold`).
        public let owner: String
        /// Why it holds, in a few words.
        public let reason: String
        /// Its hard limit, ms.
        public var limitMilliseconds: Double
        /// The holds that ended.
        public var count = 0
        /// How many ended each way, by ``End`` raw value.
        public var endedBy: [String: Int] = [:]
        /// The longest hold, ms.
        public var maxMilliseconds: Double = 0
        /// All holds together, ms.
        public var totalMilliseconds: Double = 0
        /// The holds longer than two 60 Hz frames (33.4 ms).
        public var overTwoFrames = 0

        enum CodingKeys: String, CodingKey {
            case owner, reason, count
            case limitMilliseconds = "limit_ms"
            case endedBy = "ended_by"
            case maxMilliseconds = "max_ms"
            case totalMilliseconds = "total_ms"
            case overTwoFrames = "over_two_frames"
        }
    }

    private let rows = Mutex<[String: Row]>([:])

    public init() {}

    /// `CLOCK_UPTIME_RAW` now, in ns: a hold's begin instant.
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Records one ended hold of `owner`, begun at `began` (``now()``).
    public func record(owner: String, reason: String, limit: Duration, began: UInt64, end: End) {
        let held = Double(Self.now() &- began) / 1_000_000
        let limitMilliseconds = Double(limit.components.seconds) * 1_000 + Double(limit.components.attoseconds) / 1e15
        rows.withLock { rows in
            var row = rows[owner] ?? Row(owner: owner, reason: reason, limitMilliseconds: limitMilliseconds)
            row.limitMilliseconds = limitMilliseconds
            row.count += 1
            row.endedBy[end.rawValue, default: 0] += 1
            row.maxMilliseconds = max(row.maxMilliseconds, held)
            row.totalMilliseconds += held
            if held > 33.4 { row.overTwoFrames += 1 }
            rows[owner] = row
        }
    }

    /// Every owner's row, by owner.
    public var snapshot: [Row] {
        rows.withLock { $0.values.sorted { $0.owner < $1.owner } }
    }

    /// Starts every row over.
    public func reset() {
        rows.withLock { $0.removeAll() }
    }
}
