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
/// The kept checks belong to one head commit. A page asking for another head (a push it has seen)
/// gets no checks from the old head: that is a miss, read again at once, once per head asked.
///
/// A failed job's failing step and log excerpt (``GitHubJobFailure``) are read once per job id,
/// at most ``maximumFailureReads`` per checks read, and kept: a finished job's log never changes.
/// A read that found nothing (offline, a rate limit) is not kept; it is tried again after
/// ``failureRetry`` (30 s), doubling each time, at most ``maximumFailureTries`` times.
@MainActor
public final class GitHubChecksCache {
    private struct Entry {
        var checks: GitHubChecks?
        /// When the last read finished, good or not.
        var tried: ContinuousClock.Instant?
        var read: Task<Void, Never>?
        /// The head the last read was started for, so a page ahead of GitHub's answer is not a read per ask.
        var readFor: String?
        var touched: ContinuousClock.Instant
    }

    static let maximumKept = 16
    static let maximumFailures = 64
    static let maximumFailureReads = 4
    static let maximumFailureTries = 5
    /// A read that failed (offline, a rate limit) is not tried again before this.
    static let retry: Duration = .seconds(60)

    private let reader: @Sendable (GitHubLink) async -> GitHubChecks?
    private let failureReader: @Sendable (_ repository: String, _ job: Int) async -> GitHubJobFailure?
    private var entries: [URL: Entry] = [:]
    private var failures: [Int: GitHubJobFailure] = [:]
    private var failureReads: [Int: Task<Void, Never>] = [:]
    /// Jobs whose failure read found nothing: how many times, and when it may be tried again.
    /// The first wait before a failure read that found nothing is tried again (tests shorten it).
    var failureRetry: Duration = .seconds(30)
    private var failureMisses: [Int: (tries: Int, next: ContinuousClock.Instant)] = [:]
    /// GitHub calls made, for the tests and the PR's before/after count.
    private(set) var reads = 0
    private(set) var failureCalls = 0

    public init(reader: (@Sendable (GitHubLink) async -> GitHubChecks?)? = nil,
                failureReader: (@Sendable (_ repository: String, _ job: Int) async -> GitHubJobFailure?)? = nil) {
        // Nil: the user's gh (tests pass their own).
        self.reader = reader ?? { await GitHubChecks.read($0) }
        self.failureReader = failureReader ?? { await GitHubJobFailure.read(repository: $0, job: $1) }
    }

    /// What is kept for `link` at `head` (any head when empty), with each failed job's failure when
    /// read; starts a read when stale. Waits only when nothing is kept for that head yet, so the first
    /// ask draws the dashboard and later ones never wait.
    public func answer(_ link: GitHubLink, head: String = "") async -> (checks: GitHubChecks?, reading: Bool) {
        let task = startRead(link, head: head)
        if !Self.matches(entries[link.url]?.checks, head), let task { await task.value }
        let entry = entries[link.url]
        let checks = entry?.checks.flatMap { Self.matches($0, head) ? withFailures($0) : nil }
        return (checks, entry?.read != nil)
    }

    private static func matches(_ checks: GitHubChecks?, _ head: String) -> Bool {
        guard let checks else { return false }
        return head.isEmpty || checks.head == head
    }

    /// The Actions runs with a failed job in what is kept for `link`: the only runs a re-run may name.
    public func failedRuns(_ link: GitHubLink) -> Set<Int> {
        Set(entries[link.url]?.checks?.jobs.filter { $0.state == "failed" }.compactMap(\.run) ?? [])
    }

    /// The next ask reads again (a re-run started, so the kept answer is out of date).
    public func expire(_ link: GitHubLink) {
        entries[link.url]?.tried = nil
    }

    private func stale(_ entry: Entry?, head: String) -> Bool {
        guard let entry, let tried = entry.tried else { return true }
        // Another head's checks are a miss, unless a read for this head already ran (GitHub lags the page).
        if let checks = entry.checks, !Self.matches(checks, head), entry.readFor != head { return true }
        return ContinuousClock.now - tried >= (entry.checks?.freshness ?? Self.retry)
    }

    private func startRead(_ link: GitHubLink, head: String) -> Task<Void, Never>? {
        if let running = entries[link.url]?.read { return running }
        guard stale(entries[link.url], head: head) else { return nil }
        let reader = reader
        reads += 1
        // task-owner: one checks read per pull request at a time; every page asking shares it.
        let task = Task { [weak self] in
            let checks = await reader(link)
            self?.record(checks, for: link)
        }
        var entry = entries[link.url] ?? Entry(touched: .now)
        entry.read = task
        entry.readFor = head
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
        let now = ContinuousClock.now
        let wanted = checks.jobs.filter { job in
            guard job.state == "failed", job.id > 0, failures[job.id] == nil, failureReads[job.id] == nil else { return false }
            guard let miss = failureMisses[job.id] else { return true }
            return miss.tries < Self.maximumFailureTries && now >= miss.next
        }
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
        guard let failure else {
            // Nothing found: tried again later (a later checks read asks), each wait twice the one before.
            let tries = (failureMisses[job]?.tries ?? 0) + 1
            failureMisses[job] = (tries, .now + failureRetry * (1 << min(tries - 1, 10)))
            while failureMisses.count > Self.maximumFailures, let other = failureMisses.keys.first(where: { $0 != job }) {
                failureMisses[other] = nil
            }
            return
        }
        failureMisses[job] = nil
        failures[job] = failure
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

    /// Waits for every checks read, then every failure read, running now (tests).
    func settle() async {
        for task in entries.values.compactMap(\.read) { await task.value }
        for task in Array(failureReads.values) { await task.value }
    }
}
