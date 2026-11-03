import Foundation

/// One long job of a Mac's cmux-tui owner (plans/cmux-next/long-jobs-DESIGN.md): a cleanup, a
/// compaction, journal maintenance. The phone reads them read-only (`jobs-list` at connect, then the
/// `jobs-changed` event; capability `long_jobs`, issue 13742) and shows the first one while any runs.
/// A Mac without the capability shows none.
public struct MacLongJob: Equatable, Sendable, Identifiable {
    public var id: String
    /// A stable dotted id (`registry.output_cleanup`); ``displayTitle`` names the known ones.
    public var kind: String
    /// The daemon's own (English) title, shown for a kind the phone does not name.
    public var title: String
    public var done: UInt64?
    public var total: UInt64?
    /// What it holds up (`startup`, `terminals`, `workspaces`, `history`, `quit`, `none`).
    public var blocks: [String]

    public init(id: String, kind: String, title: String, done: UInt64? = nil, total: UInt64? = nil, blocks: [String] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.done = done
        self.total = total
        self.blocks = blocks
    }

    /// Whole percent (0...99) while the job's size is known; never 100 while it runs.
    public var percent: Int? {
        guard let done, let total, total > 0 else { return nil }
        return Int(min(99, done.saturatingMultiplied(by: 100) / total))
    }

    /// The title the phone shows. The job's `detail` (the daemon's step text) is not shown on the phone.
    public var displayTitle: String {
        switch kind {
        case "registry.output_cleanup": String(localized: "Cleaning up stored terminal output")
        case "registry.output_cleanup.stage": String(localized: "Preparing the stored output cleanup")
        case "registry.output_cleanup.remove_backup": String(localized: "Removing old stored terminal output")
        case "registry.open": String(localized: "Opening your saved sessions")
        case "terminal.adopt_hosts": String(localized: "Reconnecting your terminals")
        case "journal.maintenance": String(localized: "Tidying the session journal")
        case "registry.ledger_retention": String(localized: "Trimming old session history")
        case "registry.ledger_check": String(localized: "Checking session history")
        case "registry.history_check": String(localized: "Checking terminal history")
        case "registry.compact": String(localized: "Compacting stored sessions")
        default: title.isEmpty ? kind : title
        }
    }

    /// "Cleaning up stored terminal output 43%".
    public var summary: String {
        percent.map { "\(displayTitle) \($0)%" } ?? displayTitle
    }

    /// The jobs of a `jobs-list` reply's `data` or a `jobs-changed` event (`{"jobs":[...]}`); a job
    /// without an id is skipped, every other field is optional.
    public static func list(_ object: [String: Any]?) -> [MacLongJob] {
        guard let jobs = object?["jobs"] as? [[String: Any]] else { return [] }
        return jobs.compactMap { job in
            guard let id = job["id"] as? String, !id.isEmpty else { return nil }
            func count(_ key: String) -> UInt64? { (job[key] as? NSNumber).flatMap { $0.int64Value >= 0 ? UInt64($0.int64Value) : nil } }
            let kind = job["kind"] as? String ?? "unknown"
            return MacLongJob(id: id, kind: kind, title: job["title"] as? String ?? kind, done: count("done"), total: count("total"),
                              blocks: job["blocks"] as? [String] ?? [])
        }
    }
}

private extension UInt64 {
    func saturatingMultiplied(by other: UInt64) -> UInt64 {
        let (value, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? .max : value
    }
}
