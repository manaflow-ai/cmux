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
    /// The workspaces a cmux Classic import opened (nil for other sources, and until it is done).
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
    public var fraction: Double {
        guard phase != .done else { return 1 }
        let done = Double(steps.filter(\.done).count)
        return min(1, (done + min(max(stepFraction, 0), 1)) / Double(max(steps.count, 1)))
    }

    /// The first step not done.
    public var nextStep: Int? { steps.firstIndex { !$0.done } }

    public var isActive: Bool { phase == .running }

    /// Whether the steps left can run with no prompt, so a relaunch may resume
    /// them on its own: a Chromium browser's cookies need a Keychain prompt.
    public var resumesQuietly: Bool {
        guard kind == .browser, let browser else { return false }
        let left = steps.filter { !$0.done }.flatMap(\.kinds)
        return !left.contains(.passwords) && !(browser.family == .chromium && left.contains(.cookies))
    }

    // MARK: Transitions (pure; the runner saves after each)

    public mutating func progressed(_ fraction: Double, now: Date) {
        stepFraction = fraction
        updatedAt = now
    }

    public mutating func finishedStep(_ index: Int, counts added: ImportCounts, now: Date) {
        guard steps.indices.contains(index) else { return }
        steps[index].done = true
        counts = counts + added
        stepFraction = 0
        updatedAt = now
        if nextStep == nil { phase = .done; pause = nil }
    }

    /// A cmux Classic import ended, having opened `workspaces` (0 when everything was here already).
    public mutating func importedClassic(_ workspaces: Int, now: Date) {
        opened = workspaces
        finishedStep(0, counts: ImportCounts(), now: now)
    }

    public mutating func paused(_ reason: Pause, now: Date) {
        guard phase == .running else { return }
        phase = .paused
        pause = reason
        updatedAt = now
    }

    public mutating func resumed(now: Date) {
        guard phase == .paused || phase == .failed else { return }
        phase = .running
        pause = nil
        failure = nil
        // The step starts over, so its progress does too (not the cut-off run's fraction).
        stepFraction = 0
        updatedAt = now
    }

    public mutating func failed(_ reason: Failure, now: Date) {
        phase = .failed
        failure = reason
        pause = nil
        updatedAt = now
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
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job } else { jobs.append(job) }
    }

    public mutating func update(_ id: String, _ change: (inout ImportJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    public mutating func remove(_ id: String) { jobs.removeAll { $0.id == id } }

    /// A relaunch's view of the file: a job that was running was cut off, and
    /// old finished jobs go.
    public mutating func relaunched(now: Date) {
        jobs.removeAll { $0.phase == .done && now.timeIntervalSince($0.updatedAt) > Self.keepFinished }
        for index in jobs.indices where jobs[index].phase == .running {
            jobs[index].paused(.interrupted, now: now)
        }
    }

    /// The file's ledger; an empty one when it is missing, from a newer schema or unreadable.
    public static func load(from url: URL) -> ImportJobLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder.importJobs.decode(ImportJobLedger.self, from: data),
              ledger.schema == currentSchema else { return ImportJobLedger() }
        return ledger
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
        let steps = finding.profiles.enumerated().compactMap { index, profile -> Step? in
            let kinds = Self.oneClickKinds.filter(profile.kinds.contains)
            return finding.kind == .browser && kinds.isEmpty ? nil
                : Step(profile: finding.kind == .browser ? profile.directoryName : "", kinds: kinds, intoDefault: index == 0)
        }
        self.init(id: finding.id, kind: finding.kind, browser: finding.browser,
                  steps: finding.kind == .browser ? steps : [], now: now)
    }

    /// A Chief request's job: that site's cookies from the browser's first profile, into the default profile.
    public init(request: ImportRequest, profile: String, now: Date) {
        self.init(id: request.id, kind: .browser, browser: request.browser, site: request.site,
                  steps: [Step(profile: profile, kinds: [.cookies], intoDefault: true)], now: now)
    }
}
