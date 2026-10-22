public import Foundation

/// Decodes GitHub check-run and commit-status payloads into a small UI value.
public struct PullRequestDeliveryStatusParser: Sendable {
    private struct CheckRunsPayload: Decodable {
        let checkRuns: [CheckRun]

        enum CodingKeys: String, CodingKey {
            case checkRuns = "check_runs"
        }
    }

    private struct CheckRun: Decodable {
        let name: String
        let status: String
        let conclusion: String?
    }

    private struct CommitStatusPayload: Decodable {
        let statuses: [CommitStatus]
    }

    private struct CommitStatus: Decodable {
        let context: String
        let state: String
        let targetURL: String?

        enum CodingKeys: String, CodingKey {
            case context
            case state
            case targetURL = "target_url"
        }
    }

    private struct Counts {
        var passed = 0
        var failed = 0
        var pending = 0
        var neutral = 0

        var total: Int { passed + failed + pending + neutral }

        var state: PullRequestCheckState {
            if failed > 0 { return .failure }
            if pending > 0 { return .pending }
            if passed > 0 { return .success }
            if neutral > 0 { return .neutral }
            return .neutral
        }
    }

    /// Creates a parser.
    public init() {}

    /// Parses the payloads returned by GitHub's check-runs and commit-status APIs.
    ///
    /// Deployment providers commonly publish a commit status whose context
    /// contains `deploy`, `preview`, or a provider name such as `Vercel`. Those
    /// statuses are kept separate from the build/test aggregate so the sidebar
    /// can show both facts without provider-specific integrations.
    public func parse(checkRunsData: Data, commitStatusData: Data) -> PullRequestDeliveryStatus {
        let checkRuns = (try? JSONDecoder().decode(CheckRunsPayload.self, from: checkRunsData))?.checkRuns ?? []
        let statuses = (try? JSONDecoder().decode(CommitStatusPayload.self, from: commitStatusData))?.statuses ?? []

        var counts = Counts()
        for run in checkRuns {
            if run.status.lowercased() != "completed" {
                counts.pending += 1
            } else if Self.failedConclusions.contains(run.conclusion?.lowercased() ?? "") {
                counts.failed += 1
            } else if run.conclusion?.lowercased() == "success" {
                counts.passed += 1
            } else {
                counts.neutral += 1
            }
        }

        var deployment: PullRequestDeploymentSummary?
        for status in statuses {
            if Self.isDeploymentContext(status.context) {
                let next = PullRequestDeploymentSummary(
                    name: status.context,
                    state: Self.deploymentState(for: status.state),
                    url: status.targetURL.flatMap(URL.init(string:))
                )
                if deployment == nil || Self.deploymentPriority(next.state) > Self.deploymentPriority(deployment!.state) {
                    deployment = next
                }
            } else if !checkRuns.contains(where: { $0.name == status.context }) {
                switch status.state.lowercased() {
                case "success": counts.passed += 1
                case "failure", "error": counts.failed += 1
                case "pending": counts.pending += 1
                default: counts.neutral += 1
                }
            }
        }

        let checks: PullRequestCheckSummary? = counts.total == 0
            ? nil
            : PullRequestCheckSummary(
                state: counts.state,
                passedCount: counts.passed,
                failedCount: counts.failed,
                pendingCount: counts.pending,
                totalCount: counts.total,
                neutralCount: counts.neutral
            )
        return PullRequestDeliveryStatus(
            checks: checks,
            deployment: deployment
        )
    }

    private static let failedConclusions: Set<String> = [
        "failure", "timed_out", "cancelled", "action_required", "stale", "startup_failure"
    ]

    private static func isDeploymentContext(_ context: String) -> Bool {
        let value = context.lowercased()
        return value.contains("deploy")
            || value.contains("preview")
            || value.contains("vercel")
            || value.contains("netlify")
            || value.contains("render")
    }

    private static func deploymentState(for rawValue: String) -> PullRequestDeploymentState {
        switch rawValue.lowercased() {
        case "success": return .live
        case "failure", "error": return .failure
        case "pending": return .pending
        case "inactive": return .inactive
        default: return .unknown
        }
    }

    private static func deploymentPriority(_ state: PullRequestDeploymentState) -> Int {
        switch state {
        case .failure: return 4
        case .pending: return 3
        case .live: return 2
        case .inactive: return 1
        case .unknown: return 0
        }
    }
}
