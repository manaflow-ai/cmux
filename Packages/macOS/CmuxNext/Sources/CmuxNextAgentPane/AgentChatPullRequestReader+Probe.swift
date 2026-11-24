import Foundation
import os

/// The cheap half of a refresh (Leo 2026-11-07, of the hover card's reads: "some sort of diff for
/// when you need to actually pull the GitHub previews ... using it at a good pace so to not starve
/// it"): one batched GraphQL ask for only what tells a cached pull request has changed, so the full
/// read runs only for the ones that did. And the rate limit every GraphQL read reports, so
/// ``AgentReplyPullRequests`` can back off before the user's quota runs out.
///
/// GitHub's GraphQL API has no conditional requests: it sends no ETag and ignores
/// `If-None-Match`, so a 304 that costs nothing is not on offer for any of these reads. The probe
/// is the next best thing: one call for up to ``batchSize`` pull requests, the lowest point cost a
/// query has, in place of a full read of each.
nonisolated extension AgentChatPullRequestReader {
    /// Runs gh for a test: the arguments and folder in, the output out.
    typealias Runner = @Sendable (_ arguments: [String], _ folder: String?) async -> Data?

    /// The calls to GitHub a reader made, by kind, for the before-and-after measure of its quota
    /// use. Shared by every copy of the reader it is given to.
    nonisolated final class Calls: Sendable {
        nonisolated enum Kind: Sendable {
            /// A full batched `gh api graphql` read.
            case read
            /// A batched `gh api graphql` probe of what changed.
            case probe
            /// One `gh pr view`.
            case view
            /// One `gh pr diff`, for the GitHub page's diff tab.
            case diff
        }

        nonisolated struct Counts: Equatable, Sendable {
            var reads = 0
            var probes = 0
            var views = 0
            var diffs = 0

            var total: Int { reads + probes + views }
        }

        private let state = OSAllocatedUnfairLock(initialState: Counts())

        init() {}

        var counts: Counts { state.withLock { $0 } }

        func count(_ kind: Kind) {
            state.withLock { counts in
                switch kind {
                case .read: counts.reads += 1
                case .probe: counts.probes += 1
                case .view: counts.views += 1
                case .diff: counts.diffs += 1
                }
            }
        }
    }

    /// The GraphQL rate limit as a read left it: points per hour, those left, and when they refill.
    nonisolated struct RateLimit: Equatable, Sendable {
        var limit: Int
        var remaining: Int
        var resetAt: Date
    }

    /// A batched read's answers (``read(urls:)``) and the rate limit its last GraphQL call reported.
    nonisolated struct Batch: Sendable {
        var answers: [String: AgentPanePullRequest?]
        var rate: RateLimit?
    }

    /// What the probe reads of one pull request: enough to tell whether its cached answer still
    /// holds.
    nonisolated struct Probe: Equatable, Sendable {
        /// GitHub's `updatedAt`, as the full read records it.
        var updatedAt: String
        /// `open`, `draft`, `merged` or `closed`, as ``AgentPanePullRequest/state`` says it.
        var state: String
        /// The head commit's rollup fingerprint (``rollupFingerprint(_:)``); empty when not asked or
        /// there are no checks.
        var rollupState: String
        /// The base branch tip's rollup fingerprint, asked with the head's: base CI moves neither the
        /// pull request's `updatedAt` nor its head rollup, but it changes which failures are
        /// "already red on base" (review of #37571 at 3548ad60). Empty when not asked.
        var baseRollupState: String = ""
        /// GitHub's `mergeable`, lower-cased, `unknown` as empty, as the full read records it: it
        /// resolves or changes as the base moves with no `updatedAt` (review of #37571 at 664acfbe).
        var mergeable: String = ""
    }

    /// A probe's answers, by URL: nil for a pull request GitHub answered null for; a URL the answer
    /// does not cover is left out, as ``pullRequests(fromGraphQL:_:)`` leaves it.
    nonisolated struct ProbeResult: Sendable {
        var probes: [String: Probe?]
        var rate: RateLimit?
    }

    /// The rate limit, asked for in every GraphQL query: GitHub answers it from the same call and
    /// charges nothing more for it.
    static let rateLimitField = "rateLimit { limit remaining resetAt cost }"

    /// Probes the github.com pull requests at `urls` (others are left out), one `gh api graphql`
    /// per ``batchSize``. `checks` names the ones whose head rollup is asked too.
    func probe(_ urls: [String], checks: Set<String>) async -> ProbeResult {
        let targets = urls.compactMap(Target.init(url:))
        var result = ProbeResult(probes: [:], rate: nil)
        for start in stride(from: 0, to: targets.count, by: Self.batchSize) {
            if let rate = result.rate, rate.remaining < AgentReplyPullRequests.Budget.hardFloor { break }
            let batch = Array(targets[start..<min(start + Self.batchSize, targets.count)])
            let query = Self.probeQuery(batch.map { (target: $0, checks: checks.contains($0.url)) })
            let arguments = ["api", "graphql", "--hostname", "github.com", "-f", "query=" + query]
            guard let data = await run(arguments, in: nil, anyExit: true, kind: .probe) else { continue }
            result.probes.merge(Self.probes(fromGraphQL: data, batch)) { $1 }
            result.rate = Self.rateLimit(fromGraphQL: data) ?? result.rate
        }
        return result
    }

    /// The probe for `targets`, aliased `p<i>` as ``query(_:)`` aliases them: `updatedAt` and the
    /// state, and for a target marked so, the head commit's rollup sum.
    ///
    /// `updatedAt` moves with a push, a comment, a review, a label, a title or a state change, but
    /// not with a check: a CI run finishing leaves the pull request's `updatedAt` alone. An open
    /// pull request's checks are therefore asked as well, as the one `state` of the rollup (no
    /// contexts), so a run that finishes, or a settled red someone re-runs, refreshes its card.
    /// A merged or closed one is not asked: its checks no longer change what the card says.
    static func probeQuery(_ targets: [(target: Target, checks: Bool)]) -> String {
        let aliases = targets.enumerated().map { index, entry in
            let checks = entry.checks ? " commits(last: 1) { nodes { commit { statusCheckRollup { state \(rollupCounts) } } } }"
                + " baseRef { target { ... on Commit { statusCheckRollup { state \(rollupCounts) } } } }" : ""
            return "p\(index): repository(owner: \"\(entry.target.owner)\", name: \"\(entry.target.name)\") "
                + "{ issueOrPullRequest(number: \(entry.target.number)) { __typename "
                + "... on PullRequest { updatedAt state isDraft mergeable\(checks) } ... on Issue { updatedAt state stateReason } } }"
        }
        return "query { \(rateLimitField) \(aliases.joined(separator: " ")) }"
    }

    /// Each target's probe in a GraphQL answer, by URL, with the same rules for a null or an error
    /// as ``pullRequests(fromGraphQL:_:)``.
    static func probes(fromGraphQL data: Data, _ targets: [Target]) -> [String: Probe?] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["data"] as? [String: Any] else { return [:] }
        let unanswered = Set(((object["errors"] as? [[String: Any]]) ?? []).compactMap { error -> String? in
            guard (error["type"] as? String) != "NOT_FOUND" else { return nil }
            return (error["path"] as? [Any])?.first as? String
        })
        var result: [String: Probe?] = [:]
        for (index, target) in targets.enumerated() {
            guard let alias = answers["p\(index)"] else { continue }
            guard let view = (alias as? [String: Any])?["issueOrPullRequest"] as? [String: Any] else {
                if !unanswered.contains("p\(index)") { result[target.url] = .some(nil) }
                continue
            }
            // An issue's state as the full read keeps it (``issueView(_:)``): not planned is its own.
            let issue = view["__typename"] as? String == "Issue" ? issueView(view) : view
            let state = (issue["state"] as? String)?.lowercased() ?? "open"
            let baseTarget = (view["baseRef"] as? [String: Any])?["target"] as? [String: Any]
            let commit = ((view["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last?["commit"] as? [String: Any]
            result[target.url] = .some(Probe(updatedAt: view["updatedAt"] as? String ?? "",
                                             state: state == "open" && view["isDraft"] as? Bool == true ? "draft" : state,
                                             rollupState: rollupFingerprint(commit?["statusCheckRollup"] as? [String: Any]),
                                             baseRollupState: rollupFingerprint(baseTarget?["statusCheckRollup"] as? [String: Any]),
                                             mergeable: Self.mergeable(view["mergeable"])))
        }
        return result
    }

    /// The rollup's checks counted by state, asked beside its sum in the probe and the full read.
    /// The sum alone stays `PENDING` while one check after another finishes, and none of them moves
    /// `updatedAt`, so a probe of the sum alone kept stale counts as fresh (review of #37571 at
    /// 1eac536b); the counts change with every check that finishes.
    static let rollupCounts = "counts: contexts(first: 1) { checkRunCountsByState { state count } "
        + "statusContextCountsByState { state count } }"

    /// A rollup's sum, upper-cased, then its counts by state when GitHub gave them
    /// (`PENDING IN_PROGRESS:2,SUCCESS:5|PENDING:1`); empty with no rollup. Equal fingerprints mean
    /// the card's checks row has nothing new to say.
    static func rollupFingerprint(_ rollup: [String: Any]?) -> String {
        guard let state = (rollup?["state"] as? String)?.uppercased() else { return "" }
        let counts = rollup?["counts"] as? [String: Any]
        let byState = ["checkRunCountsByState", "statusContextCountsByState"].map { key in
            ((counts?[key] as? [[String: Any]]) ?? []).compactMap { entry -> String? in
                guard let name = entry["state"] as? String, let count = entry["count"] as? Int else { return nil }
                return "\(name.uppercased()):\(count)"
            }.sorted().joined(separator: ",")
        }
        return byState.allSatisfy(\.isEmpty) ? state : state + " " + byState.joined(separator: "|")
    }

    /// `mergeable` as ``AgentPanePullRequest`` keeps it: lower-cased, `unknown` and absent as empty.
    static func mergeable(_ value: Any?) -> String {
        let text = (value as? String)?.lowercased() ?? ""
        return text == "unknown" ? "" : text
    }

    /// The rate limit a GraphQL answer reports; nil when it reports none (a failed read).
    static func rateLimit(fromGraphQL data: Data) -> RateLimit? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = (object["data"] as? [String: Any])?["rateLimit"] as? [String: Any],
              let limit = rate["limit"] as? Int, let remaining = rate["remaining"] as? Int,
              let reset = rate["resetAt"] as? String, let resetAt = try? Date(reset, strategy: .iso8601) else { return nil }
        return RateLimit(limit: limit, remaining: remaining, resetAt: resetAt)
    }
}
