public import Foundation

/// One long job: work that takes longer than about a second and blocks, delays or slows something the
/// person can do (plans/cmux-next/long-jobs-DESIGN.md). The same shape travels on the daemon wire
/// (`jobs-list`, `jobs-changed`, `server ensure --restore-progress` lines), sits in the daemon's
/// `long-jobs.json` status file, and is the app model of ``LongJobs``. Lives in this core module so every
/// package that does slow work can register in the one registry.
///
/// Decoding is lenient so an older or newer daemon never breaks the list: every field but `id`
/// may be absent (a missing `kind` reads `unknown`, a missing `title` reads the kind) and unknown
/// fields and `blocks` values are kept or ignored.
public struct LongJob: Sendable, Hashable, Identifiable, Codable {
    /// What a job holds up (`blocks` on the wire). Unknown values stay as their raw string.
    public struct Block: RawRepresentable, Sendable, Hashable, Codable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }

        /// The owner does not accept clients yet.
        public static let startup = Block("startup")
        public static let terminals = Block("terminals")
        public static let workspaces = Block("workspaces")
        public static let history = Block("history")
        /// Quitting now loses or repeats the work.
        public static let quit = Block("quit")
        /// Background only, still shown.
        public static let none = Block("none")

        public init(from decoder: any Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var id: String
    /// A stable dotted id (`registry.output_cleanup`); the app localizes by it (``displayTitle``).
    public var kind: String
    /// English from the daemon's catalog: the fallback when the app has no text for `kind`.
    public var title: String
    public var detail: String?
    public var done: UInt64?
    public var total: UInt64?
    public var unit: String?
    public var startedMs: Int64
    /// Changes on every progress step or heartbeat (at least every 5 s while the job is alive).
    public var updatedMs: Int64
    public var blocks: [Block]
    public var cancellable: Bool
    /// Which machine's daemon runs it (`local`, a Cloud machine id); nil for the app's own jobs.
    /// Not on the wire: the app sets it when it merges the machines' lists.
    public var machine: String?

    public init(id: String, kind: String, title: String, detail: String? = nil, done: UInt64? = nil, total: UInt64? = nil,
                unit: String? = nil, startedMs: Int64, updatedMs: Int64? = nil, blocks: [Block] = [], cancellable: Bool = false,
                machine: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.done = done
        self.total = total
        self.unit = unit
        self.startedMs = startedMs
        self.updatedMs = updatedMs ?? startedMs
        self.blocks = blocks
        self.cancellable = cancellable
        self.machine = machine
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, done, total, unit, blocks, cancellable
        case startedMs = "started_ms"
        case updatedMs = "updated_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "unknown"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? kind
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        done = try? c.decodeIfPresent(UInt64.self, forKey: .done)
        total = try? c.decodeIfPresent(UInt64.self, forKey: .total)
        unit = try? c.decodeIfPresent(String.self, forKey: .unit)
        startedMs = (try? c.decodeIfPresent(Int64.self, forKey: .startedMs)) ?? 0
        updatedMs = (try? c.decodeIfPresent(Int64.self, forKey: .updatedMs)) ?? startedMs
        blocks = (try? c.decodeIfPresent([Block].self, forKey: .blocks)) ?? []
        cancellable = (try? c.decodeIfPresent(Bool.self, forKey: .cancellable)) ?? false
        machine = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(done, forKey: .done)
        try c.encodeIfPresent(total, forKey: .total)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encode(startedMs, forKey: .startedMs)
        try c.encode(updatedMs, forKey: .updatedMs)
        try c.encode(blocks, forKey: .blocks)
        try c.encode(cancellable, forKey: .cancellable)
    }

    /// 0...1 when `done` and a nonzero `total` are known.
    public var fraction: Double? {
        guard let done, let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    /// Whole percent (0...100) when ``fraction`` is known. Never 100 while the job still runs.
    public var percent: Int? {
        fraction.flatMap { Int(exactly: min(99, max(0, ($0 * 100).rounded(.down)))) }
    }

    public func holds(_ block: Block) -> Bool { blocks.contains(block) }

    // The kinds the app names (CmuxNextDaemonService `LongJob.displayTitle`): the daemon's
    // (cmux-tui-core `long_jobs`) and the app's own.
    public static let outputCleanupKind = "registry.output_cleanup"
    public static let outputCleanupStageKind = "registry.output_cleanup.stage"
    public static let outputCleanupRemoveBackupKind = "registry.output_cleanup.remove_backup"
    public static let registryOpenKind = "registry.open"
    public static let adoptHostsKind = "terminal.adopt_hosts"
    public static let journalMaintenanceKind = "journal.maintenance"
    public static let ledgerRetentionKind = "registry.ledger_retention"
    public static let ledgerCheckKind = "registry.ledger_check"
    public static let historyCheckKind = "registry.history_check"
    public static let compactKind = "registry.compact"
    public static let updateDownloadKind = "app.update.download"
    public static let updateInstallKind = "app.update.install"
    public static let browserImportKind = "app.browser.import"
    public static let cloudUploadKind = "app.cloud.upload"
}

/// A list of jobs as the daemon sends it (`jobs-list` reply, `jobs-changed` event, status file).
public struct LongJobList: Sendable, Hashable, Decodable {
    public var jobs: [LongJob]
    /// The status file's format (`long-jobs.json`, 1); nil on the socket.
    public var version: Int?
    /// The status file's owner process (`long-jobs.json`); nil on the socket.
    public var pid: Int32?
    public var updatedMs: Int64?

    public init(jobs: [LongJob], pid: Int32? = nil, updatedMs: Int64? = nil) {
        self.jobs = jobs
        self.pid = pid
        self.updatedMs = updatedMs
    }

    enum CodingKeys: String, CodingKey {
        case jobs, pid, version
        case updatedMs = "updated_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobs = (try? c.decodeIfPresent([LongJob].self, forKey: .jobs)) ?? []
        version = try? c.decodeIfPresent(Int.self, forKey: .version)
        pid = try? c.decodeIfPresent(Int32.self, forKey: .pid)
        updatedMs = try? c.decodeIfPresent(Int64.self, forKey: .updatedMs)
    }
}
