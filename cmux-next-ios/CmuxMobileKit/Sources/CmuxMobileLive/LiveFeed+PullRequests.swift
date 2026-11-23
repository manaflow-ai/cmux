import CmuxMobileAgentChat
import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "feed")

/// The live state of the pull requests chats opened (manaflow-ai/cmux#51332): a Feed card and a
/// workspace row say "PR #123 · Checks passing", "Merged" or "Checks failing", and offer Merge
/// once it is ready. The phone has no GitHub login; its Mac reads each pull request with its own
/// `gh` (`_acpmux/pr_state`, one fixed `gh pr view` in the chat's folder).
///
/// GitHub's quota is shared with everything else on the Mac, so the reads are few: only the
/// newest `pullReadLimit` pull requests, two at a time, an open one again only after
/// `pullFreshness`, a merged or closed one never again this run, a failed one after a doubling
/// wait. A Mac whose acpmux does not know the method is not asked again on this link.
extension LiveFeed {
    /// How many of the newest chats' pull requests are read on one pass.
    static let pullReadLimit = 24
    /// How long an open pull request's state stands before it is read again.
    static let pullFreshness: Duration = .seconds(180)
    /// Reads at once.
    static let pullConcurrency = 2

    /// What `session` did last, with its pull request's state as the Mac last read it.
    public func activity(of session: AcpmuxSession) -> ChatActivity {
        var activity = session.activity
        if let pull = activity.pullRequest, let known = pullCache[pull.url]?.summary {
            activity.pullRequest = pull.merged(with: known)
        }
        return activity
    }

    /// Reads the state of the newest chats' pull requests that are missing or stale.
    func readPullStates(_ sessions: [AcpmuxSession]) {
        guard let hub, pullStateSupported else { return }
        let now = ContinuousClock.now
        var seen = Set<URL>()
        let wanted = sessions
            .filter(Self.showsTurns(of:))
            .sorted { ($0.lastTurnEndedAt ?? $0.updatedAt ?? .distantPast) > ($1.lastTurnEndedAt ?? $1.updatedAt ?? .distantPast) }
            .compactMap { session -> (String, PullRequestSummary)? in
                guard let pull = session.activity.pullRequest, seen.insert(pull.url).inserted else { return nil }
                return (session.id, pull)
            }
            .prefix(Self.pullReadLimit)
            .filter { _, pull in
                guard pullReads[pull.url] == nil else { return false }
                guard let entry = pullCache[pull.url] else { return true }
                return entry.summary.isOpen && now >= entry.next
            }
        for (sessionID, pull) in wanted { pullQueue.append((sessionID, pull.url)) }
        drainPullQueue(hub)
    }

    private func drainPullQueue(_ hub: AcpmuxHub) {
        while pullReads.count < Self.pullConcurrency, !pullQueue.isEmpty {
            let (sessionID, url) = pullQueue.removeFirst()
            guard pullReads[url] == nil else { continue }
            // task-owner: LiveFeed.pullReads: one `_acpmux/pr_state` read per pull request; it ends with its request.
            pullReads[url] = Task { [weak self] in
                let result: Result<JSONValue, any Error>
                do {
                    result = .success(try await hub.request("_acpmux/pr_state", .object([
                        "sessionId": .string(sessionID), "pr": .string(url.absoluteString),
                    ]), timeout: .seconds(55)))
                } catch {
                    result = .failure(error)
                }
                guard let self else { return }
                pullReads[url] = nil
                settlePullRead(url, result)
                guard pullStateSupported, let hub = self.hub else { return }
                drainPullQueue(hub)
            }
        }
    }

    private func settlePullRead(_ url: URL, _ result: Result<JSONValue, any Error>) {
        let now = ContinuousClock.now
        switch result {
        case .success(let answer):
            guard let read = Self.pullSummary(answer, url: url) else {
                // An answer this build cannot read: wait as for a failure, never ask again at once.
                backOff(url, now: now)
                return
            }
            let summary = pullCache[url].map { $0.summary.merged(with: read) } ?? read
            pullCache[url] = PullEntry(summary: summary, next: now + Self.pullFreshness, failures: 0)
            applyPullState(summary)
        case .failure(let error):
            if let rpc = error as? AcpmuxConnection.RPCError, rpc.code == -32601 {
                // An older acpmux: nothing to ask on this link.
                log.info("feed pr_state not supported on this Mac")
                pullStateSupported = false
                pullQueue = []
                return
            }
            backOff(url, now: now)
        }
    }

    /// The next read of `url` waits twice as long as the last failed one did (at most 16 times).
    private func backOff(_ url: URL, now: ContinuousClock.Instant) {
        let failures = (pullCache[url]?.failures ?? 0) + 1
        let wait = Self.pullFreshness * (1 << min(failures, 4))
        let summary = pullCache[url]?.summary ?? PullRequestSummary(url: url, number: 0)
        pullCache[url] = PullEntry(summary: summary, next: now + wait, failures: failures)
    }

    /// Every card of that pull request takes its state, and the workspace rows read it again.
    private func applyPullState(_ summary: PullRequestSummary) {
        for item in store.items where item.pullRequest?.url == summary.url && item.pullRequest != summary {
            var next = item
            next.pullRequest = item.pullRequest.map { $0.merged(with: summary) } ?? summary
            store.upsert(next, atTop: false)
        }
        onPullStatesChange?()
    }

    /// `_acpmux/pr_state`'s answer (`server/pr_state.rs`): `state`, `draft`, `mergeable`
    /// (`mergeable`, `conflicts`), the failing, pending and passed check counts, `title`.
    static func pullSummary(_ answer: JSONValue, url: URL) -> PullRequestSummary? {
        guard let number = answer["pr"]?.numberValue.map({ Int($0) }), number > 0 else { return nil }
        let draft = answer["draft"] == .bool(true)
        let state: PullRequestSummary.State? = switch answer["state"]?.stringValue?.lowercased() {
        case "merged": .merged
        case "closed": .closed
        case "open": draft ? .draft : .open
        default: nil
        }
        let failing = answer["failingChecks"]?.arrayValue?.count ?? 0
        let pending = Int(answer["pendingChecks"]?.numberValue ?? 0)
        let passed = Int(answer["passedChecks"]?.numberValue ?? 0)
        let checks: PullRequestSummary.Checks? = failing > 0 ? .failing : pending > 0 ? .pending : passed > 0 ? .passing : nil
        let mergeable: Bool? = switch answer["mergeable"]?.stringValue {
        case "mergeable": true
        case "conflicts": false
        default: nil
        }
        let title = answer["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return PullRequestSummary(url: url, number: number, title: title, state: state, checks: checks, mergeable: mergeable)
    }
}

/// One pull request's last read and when it may be read again.
struct PullEntry {
    var summary: PullRequestSummary
    var next: ContinuousClock.Instant
    var failures: Int
}
