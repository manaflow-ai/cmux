import Foundation

/// A rollup entry with the provider/workflow/event identity needed to replace
/// reruns without collapsing similarly named jobs from different workflows.
struct PullRequestCheckContext: Sendable {
    let check: PullRequestCheck
    let identity: PullRequestCheckIdentity
    let startedAt: String
    let runNumber: Int64?

    init?(_ node: [String: Any]) {
        guard let id = node["id"] as? String else { return nil }
        switch node["__typename"] as? String {
        case "CheckRun":
            guard let name = node["name"] as? String, let status = node["status"] as? String else { return nil }
            let suite = node["checkSuite"] as? [String: Any]
            let app = suite?["app"] as? [String: Any]
            let run = suite?["workflowRun"] as? [String: Any]
            let workflow = run?["workflow"] as? [String: Any]
            identity = PullRequestCheckIdentity(
                kind: "run", name: name, application: app?["id"] as? String ?? "",
                workflow: workflow?["id"] as? String ?? "", event: run?["event"] as? String ?? ""
            )
            startedAt = node["startedAt"] as? String ?? ""
            runNumber = (node["databaseId"] as? NSNumber)?.int64Value
            check = PullRequestCheck(
                id: id, name: name,
                status: PullRequestCheckStatus(checkRunStatus: status, conclusion: node["conclusion"] as? String),
                detailsURL: (node["detailsUrl"] as? String).flatMap(URL.init(string:))
            )
        case "StatusContext":
            guard let name = node["context"] as? String, let state = node["state"] as? String else { return nil }
            identity = PullRequestCheckIdentity(kind: "status", name: name, application: "", workflow: "", event: "")
            startedAt = node["createdAt"] as? String ?? ""
            runNumber = nil
            let status: PullRequestCheckStatus
            switch state.lowercased() {
            case "success": status = .success
            case "failure", "error": status = .failure
            case "pending", "expected": status = .pending
            default: status = .unavailable
            }
            check = PullRequestCheck(
                id: id, name: name, status: status,
                detailsURL: (node["targetUrl"] as? String).flatMap(URL.init(string:))
            )
        default: return nil
        }
    }

    /// Check-run numbers preserve attempt order before a queued rerun starts.
    /// Legacy status contexts use their creation timestamps.
    func isNewer(than other: Self) -> Bool {
        if let runNumber, let otherNumber = other.runNumber {
            return runNumber > otherNumber
        }
        return startedAt > other.startedAt
    }
}
