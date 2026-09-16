import Foundation

extension PullRequestProbeService {
    nonisolated func fetchCheckRuns(
        repoSlug: String, sha: String, authHeader: String
    ) async -> (checks: [PullRequestCheck], complete: Bool) {
        var checks: [String: PullRequestCheck] = [:]
        for page in 1...10 {
            guard !Task.isCancelled else { return (Array(checks.values), false) }
            let response = await performRequest(
                endpoint: "repos/\(repoSlug)/commits/\(sha)/check-runs?filter=latest&per_page=100&page=\(page)",
                authHeader: authHeader
            )
            guard let payload = response?.decode(WorkspacePullRequestCheckRunsResponse.self) else {
                return (Array(checks.values), false)
            }
            for run in payload.checkRuns {
                let id = "run:\(run.id)"
                checks[id] = PullRequestCheck(
                    id: id, name: run.name,
                    status: PullRequestCheckStatus(checkRunStatus: run.status, conclusion: run.conclusion),
                    detailsURL: run.detailsURL.flatMap(URL.init(string:))
                )
            }
            if page * 100 >= payload.totalCount { return (Array(checks.values), true) }
            if payload.checkRuns.isEmpty { return (Array(checks.values), false) }
        }
        return (Array(checks.values), false)
    }

    nonisolated func fetchCommitStatuses(
        repoSlug: String, sha: String, authHeader: String
    ) async -> (checks: [PullRequestCheck], complete: Bool) {
        var checks: [String: PullRequestCheck] = [:]
        for page in 1...10 {
            guard !Task.isCancelled else { return (Array(checks.values), false) }
            let response = await performRequest(
                endpoint: "repos/\(repoSlug)/commits/\(sha)/status?per_page=100&page=\(page)",
                authHeader: authHeader
            )
            guard let payload = response?.decode(WorkspacePullRequestCommitStatuses.self) else {
                return (Array(checks.values), false)
            }
            for status in payload.statuses {
                let state: PullRequestCheckStatus
                switch status.state.lowercased() {
                case "success": state = .success
                case "failure", "error": state = .failure
                case "pending": state = .pending
                default: state = .unavailable
                }
                let id = "status:\(status.context)"
                if checks[id] == nil {
                    checks[id] = PullRequestCheck(
                        id: id, name: status.context, status: state,
                        detailsURL: status.targetURL.flatMap(URL.init(string:))
                    )
                }
            }
            if page * 100 >= payload.totalCount { return (Array(checks.values), true) }
            if payload.statuses.isEmpty { return (Array(checks.values), false) }
        }
        return (Array(checks.values), false)
    }
}
