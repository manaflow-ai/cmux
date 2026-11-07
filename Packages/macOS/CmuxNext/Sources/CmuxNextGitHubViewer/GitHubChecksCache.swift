public import Foundation
import CmuxNextAgentPane

/// The CI dashboard's checks, one entry per pull request for the whole App (the GitHub page tab
/// makes one and hands it to every page's provider, WebPageTab.swift): every GitHub page showing
/// a pull request reads through it, so two pages are one read, and a page asking every
/// few seconds gets the kept answer until it goes stale (``GitHubChecks/freshness``: 20 s while
/// a job runs or waits, 5 min once all are done). No push feed of check events reaches the App,
/// so this is the live path: reads only for pull requests a visible page asks about, at a pace
/// set by their state, never one per tab and never for a pull request no page shows.
///
/// A failed job's failing step and log excerpt (``GitHubJobFailure``) are read once per job id,
/// at most ``maximumFailureReads`` per checks read, and kept: a finished job's log never changes.
@MainActor
public final class GitHubChecksCache {
    private struct Entry {
        var checks: GitHubChecks?
        /// When the last read finished, good or not.
        var tried: ContinuousClock.Instant?
        var read: Task<Void, Never>?
        var touched: ContinuousClock.Instant
    }

    static let maximumKept = 16
    static let maximumFailures = 64
    static let maximumFailureReads = 4
    /// A read that failed (offline, a rate limit) is not tried again before this.
    static let retry: Duration = .seconds(60)

    private let reader: @Sendable (GitHubLink) async -> GitHubChecks?
    private let failureReader: @Sendable (_ repository: String, _ job: Int) async -> GitHubJobFailure?
    private var entries: [URL: Entry] = [:]
    private var failures: [Int: GitHubJobFailure] = [:]
    private var failureReads: [Int: Task<Void, Never>] = [:]
    /// GitHub calls made, for the tests and the PR's before/after count.
    private(set) var reads = 0
    private(set) var failureCalls = 0

    public init(reader: (@Sendable (GitHubLink) async -> GitHubChecks?)? = nil,
                failureReader: (@Sendable (_ repository: String, _ job: Int) async -> GitHubJobFailure?)? = nil) {
        // Nil: the user's gh (tests pass their own).
        self.reader = reader ?? { await GitHubChecks.read($0) }
        self.failureReader = failureReader ?? { await GitHubJobFailure.read(repository: $0, job: $1) }
    }

    /// What is kept for `link`, with each failed job's failure when read; starts a read when stale.
    /// Waits only when nothing is kept yet, so the first ask draws the dashboard and later ones never wait.
    public func answer(_ link: GitHubLink) async -> (checks: GitHubChecks?, reading: Bool) {
        let task = startRead(link)
        if entries[link.url]?.checks == nil, let task { await task.value }
        let entry = entries[link.url]
        return (entry?.checks.map(withFailures), entry?.read != nil)
    }

    /// The Actions runs with a failed job in what is kept for `link`: the only runs a re-run may name.
    public func failedRuns(_ link: GitHubLink) -> Set<Int> {
        Set(entries[link.url]?.checks?.jobs.filter { $0.state == "failed" }.compactMap(\.run) ?? [])
    }

    /// The next ask reads again (a re-run started, so the kept answer is out of date).
    public func expire(_ link: GitHubLink) {
        entries[link.url]?.tried = nil
    }

    private func stale(_ entry: Entry?) -> Bool {
        guard let entry, let tried = entry.tried else { return true }
        return ContinuousClock.now - tried >= (entry.checks?.freshness ?? Self.retry)
    }

    private func startRead(_ link: GitHubLink) -> Task<Void, Never>? {
        if let running = entries[link.url]?.read { return running }
        guard stale(entries[link.url]) else { return nil }
        let reader = reader
        reads += 1
        // task-owner: one checks read per pull request at a time; every page asking shares it.
        let task = Task { [weak self] in
            let checks = await reader(link)
            self?.record(checks, for: link)
        }
        var entry = entries[link.url] ?? Entry(touched: .now)
        entry.read = task
        entry.touched = .now
        entries[link.url] = entry
        trim()
        return task
    }

    private func record(_ checks: GitHubChecks?, for link: GitHubLink) {
        guard var entry = entries[link.url] else { return }
        entry.read = nil
        entry.tried = .now
        // A failed read leaves the last good answer in place.
        if let checks { entry.checks = checks }
        entries[link.url] = entry
        if let checks { readFailures(checks, repository: link.repository) }
    }

    /// Reads the failure of each failed job not read yet, a few per checks read.
    private func readFailures(_ checks: GitHubChecks, repository: String) {
        let wanted = checks.jobs.filter { $0.state == "failed" && $0.id > 0 && failures[$0.id] == nil && failureReads[$0.id] == nil }
        let reader = failureReader
        for job in wanted.prefix(Self.maximumFailureReads) {
            failureCalls += 1
            // task-owner: one failure read per job id, ever; the next checks answer carries what it found.
            failureReads[job.id] = Task { [weak self] in
                let failure = await reader(repository, job.id)
                self?.keep(failure, for: job.id)
            }
        }
    }

    private func keep(_ failure: GitHubJobFailure?, for job: Int) {
        failureReads[job] = nil
        // A read that found nothing is kept too, as an empty failure: it is not read again.
        failures[job] = failure ?? GitHubJobFailure(step: nil, excerpt: "")
        while failures.count > Self.maximumFailures, let other = failures.keys.first(where: { $0 != job }) { failures[other] = nil }
    }

    private func withFailures(_ checks: GitHubChecks) -> GitHubChecks {
        var checks = checks
        for index in checks.jobs.indices where checks.jobs[index].state == "failed" {
            checks.jobs[index].failure = failures[checks.jobs[index].id]
        }
        return checks
    }

    private func trim() {
        while entries.count > Self.maximumKept,
              let stalest = entries.filter({ $0.value.read == nil }).min(by: { $0.value.touched < $1.value.touched })?.key {
            entries[stalest] = nil
        }
    }

    /// Waits for every failure read running now (tests).
    func settle() async {
        for task in Array(failureReads.values) { await task.value }
    }
}
