public import CmuxNextBrowserImport
public import Foundation

/// One import a card started, kept on disk after every step so it survives
/// a quit or crash: a browser import is one step per profile; the other
/// sources are one step. A relaunch finds it `running`, marks it paused
/// (`interrupted`) and the runner resumes the steps that are left.
public nonisolated struct ImportJob: Codable, Sendable, Equatable, Identifiable {
    public nonisolated enum Phase: String, Codable, Sendable {
        case running
        /// Stopped before every step was done; `pause` says why.
        case paused
        case done
        case failed
    }

    public nonisolated enum Pause: String, Codable, Sendable {
        /// cmux quit or crashed mid-run.
        case interrupted
        /// The rest needs the person (a Keychain prompt, a folder grant), so it waits for Resume.
        case needsPerson
    }

    /// Why a job failed, as a key the cards turn into words (never a path or a row of data).
    public nonisolated enum Failure: String, Codable, Sendable {
        /// The person refused the folder grant or the Keychain prompt.
        case declined
        /// The source has nothing left to read (the browser was removed, a profile is gone).
        case sourceGone
        /// The import itself failed.
        case importFailed
    }

    public nonisolated struct Step: Codable, Sendable, Equatable {
        /// The browser profile folder (`Default`, `Profiles/ab12.default`); empty for one-step sources.
        public var profile: String
        public var kinds: [ImportDataKind]
        /// Into the person's default cmux browser profile (the first profile), else its own profile.
        public var intoDefault: Bool
        public var done = false

        public init(profile: String, kinds: [ImportDataKind], intoDefault: Bool) {
            self.profile = profile
            self.kinds = kinds
            self.intoDefault = intoDefault
        }
    }

    /// The card's id (`browser.chrome`, `request.cookies.chrome.github.com`): one job per card.
    public var id: String
    public var kind: ImportSourceKind
    public var browser: ImportBrowser?
    /// A Chief request's site: only its cookies come over.
    public var site: String?
    public var steps: [Step]
    public var phase: Phase
    public var pause: Pause?
    public var failure: Failure?
    /// The current step's progress, 0...1.
    public var stepFraction: Double = 0
    public var counts = ImportCounts()
    /// The workspaces a cmux Classic or Conductor import opened (nil for other sources, and until it is done).
    public var opened: Int?
    public var startedAt: Date
    public var updatedAt: Date

    public init(id: String, kind: ImportSourceKind, browser: ImportBrowser? = nil, site: String? = nil,
                steps: [Step], now: Date) {
        self.id = id
        self.kind = kind
        self.browser = browser
        self.site = site
        self.steps = steps.isEmpty ? [Step(profile: "", kinds: [], intoDefault: true)] : steps
        phase = .running
        startedAt = now
        updatedAt = now
    }

    /// The whole job's progress, 0...1.
    public var fraction: Double { facts?.fraction ?? 0 }

    /// The first step not done.
    public var nextStep: Int? { facts?.nextStep }

    public var isActive: Bool { facts?.isActive ?? false }

    /// Whether the steps left can run with no prompt, so a relaunch may resume
    /// them on its own: a Chromium browser's cookies need a Keychain prompt.
    public var resumesQuietly: Bool { facts?.resumesQuietly ?? false }

    private struct Facts: Decodable {
        var fraction: Double
        var nextStep: Int?
        var isActive: Bool
        var resumesQuietly: Bool
    }

    private var facts: Facts? {
        ImportSuggestRules.call("job_facts", ["job": self, "family": browser?.family.rawValue], as: Facts.self)
    }

    // MARK: Transitions (Rust's `Job`; the runner saves after each)

    public mutating func progressed(_ fraction: Double, now: Date) { apply(.progressed(fraction), now: now) }

    public mutating func finishedStep(_ index: Int, counts added: ImportCounts, now: Date) {
        apply(.finishedStep(index, added), now: now)
    }

    /// A cmux Classic or Conductor import ended, having opened `workspaces` (0 when everything was here already).
    public mutating func importedClassic(_ workspaces: Int, now: Date) { apply(.importedClassic(workspaces), now: now) }

    public mutating func paused(_ reason: Pause, now: Date) { apply(.paused(reason), now: now) }

    public mutating func resumed(now: Date) { apply(.resumed, now: now) }

    public mutating func failed(_ reason: Failure, now: Date) { apply(.failed(reason), now: now) }

    private enum Event: Encodable {
        case progressed(Double), finishedStep(Int, ImportCounts), importedClassic(Int), paused(Pause), resumed, failed(Failure)

        private enum Keys: String, CodingKey { case event, fraction, index, added, workspaces, reason }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .progressed(fraction):
                try container.encode("progressed", forKey: .event)
                try container.encode(fraction, forKey: .fraction)
            case let .finishedStep(index, added):
                try container.encode("finishedStep", forKey: .event)
                try container.encode(index, forKey: .index)
                try container.encode(added, forKey: .added)
            case let .importedClassic(workspaces):
                try container.encode("importedClassic", forKey: .event)
                try container.encode(workspaces, forKey: .workspaces)
            case let .paused(reason):
                try container.encode("paused", forKey: .event)
                try container.encode(reason, forKey: .reason)
            case .resumed:
                try container.encode("resumed", forKey: .event)
            case let .failed(reason):
                try container.encode("failed", forKey: .event)
                try container.encode(reason, forKey: .reason)
            }
        }
    }

    private struct Moved: Decodable { var job: ImportJob }

    private mutating func apply(_ event: Event, now: Date) {
        guard let moved = ImportSuggestRules.call("job_event", ["job": self, "event": event, "now": now], as: Moved.self) else { return }
        self = moved.job.keeping(self, now: now)
    }

    /// `self` as Rust sent it back, with what JSON does not carry exactly put back from `old`: the
    /// browser's registry row and the dates (Rust keeps them or sets `updatedAt` to `now`).
    func keeping(_ old: ImportJob, now: Date) -> ImportJob {
        var job = self
        job.browser = old.browser
        job.startedAt = old.startedAt
        job.updatedAt = ImportSuggestRules.pinned(updatedAt, to: old.updatedAt, now)
        return job
    }
}

/// Every job, as one JSON file (`import-jobs.json` in the app's support folder).
public nonisolated struct ImportJobLedger: Codable, Sendable, Equatable {
    public static let currentSchema = 1
    /// Finished jobs older than this are dropped on load.
    public static let keepFinished: TimeInterval = 14 * 24 * 3600

    public var schema = Self.currentSchema
    public var jobs: [ImportJob] = []

    public init(jobs: [ImportJob] = []) {
        self.jobs = jobs
    }

    public func job(_ id: String) -> ImportJob? { jobs.first { $0.id == id } }

    /// Adds `job`, replacing an earlier job of the same card.
    public mutating func put(_ job: ImportJob) {
        adopt(ImportSuggestRules.call("ledger_put", ["ledger": self, "job": job], as: Self.self), known: jobs + [job])
    }

    public mutating func update(_ id: String, _ change: (inout ImportJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    public mutating func remove(_ id: String) {
        adopt(ImportSuggestRules.call("ledger_remove", ["ledger": self, "id": id], as: Self.self), known: jobs)
    }

    /// A relaunch's view of the file: a job that was running was cut off, and
    /// old finished jobs go.
    public mutating func relaunched(now: Date) {
        adopt(ImportSuggestRules.call("ledger_relaunched", ["ledger": self, "now": now], as: Self.self), known: jobs, now: now)
    }

    /// Takes Rust's ledger, each job keeping its browser row and dates from the one it was.
    private mutating func adopt(_ ledger: ImportJobLedger?, known: [ImportJob], now: Date? = nil) {
        guard var ledger else { return }
        for index in ledger.jobs.indices {
            guard let old = known.last(where: { $0.id == ledger.jobs[index].id }) else { continue }
            ledger.jobs[index] = ledger.jobs[index].keeping(old, now: now ?? old.updatedAt)
        }
        self = ledger
    }

    /// The file's ledger; an empty one when it is missing, from a newer schema or unreadable.
    public static func load(from url: URL) -> ImportJobLedger {
        guard let data = try? Data(contentsOf: url) else { return ImportJobLedger() }
        return ImportSuggestRules.call("ledger_read", ["data": data.base64EncodedString()], as: Self.self) ?? ImportJobLedger()
    }

    /// Writes the ledger atomically, readable only by this user.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.importJobs.encode(self)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension JSONEncoder {
    nonisolated static var importJobs: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var importJobs: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

extension ImportJob {
    /// The kinds one click brings from a browser: no passwords, which need
    /// their own consent step (the Import from Browser window's).
    public static let oneClickKinds: [ImportDataKind] = [.history, .bookmarks, .cookies]

    /// A finding's job: one step per profile, the first into the person's
    /// default cmux profile and each other one into a profile of its own.
    public init(finding: ImportFinding, now: Date) {
        let made = ImportSuggestRules.call("job_from_finding", ["finding": finding, "now": now], as: ImportJob.self)
            ?? ImportJob(id: finding.id, kind: finding.kind, steps: [], now: now)
        self = made.made(browser: finding.browser, now: now)
    }

    /// A Chief request's job: that site's cookies from the browser's first profile, into the default profile.
    public init(request: ImportRequest, profile: String, now: Date) {
        let made = ImportSuggestRules.call("job_from_request", ["request": request, "profile": profile, "now": now], as: ImportJob.self)
            ?? ImportJob(id: request.id, kind: .browser, site: request.site, steps: [], now: now)
        self = made.made(browser: request.browser, now: now)
    }

    private func made(browser: ImportBrowser?, now: Date) -> ImportJob {
        var job = self
        job.browser = browser
        job.startedAt = now
        job.updatedAt = now
        return job
    }
}
