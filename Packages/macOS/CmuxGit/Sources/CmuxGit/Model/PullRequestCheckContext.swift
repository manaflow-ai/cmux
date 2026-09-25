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
            if let fullID = node["fullDatabaseId"] as? String {
                runNumber = Int64(fullID)
            } else {
                runNumber = (node["fullDatabaseId"] as? NSNumber)?.int64Value
                    ?? (node["databaseId"] as? NSNumber)?.int64Value
            }
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

    /// Compares attempts using the provider's numeric identifier when present.
    /// Missing identifiers and timestamps fail closed instead of guessing which
    /// queued or completed attempt should win.
    func ordering(against other: Self) -> PullRequestCheckOrdering {
        if runNumber != nil || other.runNumber != nil {
            guard let runNumber, let otherNumber = other.runNumber, runNumber != otherNumber else {
                return .ambiguous
            }
            return runNumber > otherNumber ? .newer : .older
        }
        guard !startedAt.isEmpty, !other.startedAt.isEmpty, startedAt != other.startedAt else {
            return .ambiguous
        }
        return startedAt > other.startedAt ? .newer : .older
    }

    init(check: PullRequestCheck, identity: PullRequestCheckIdentity, startedAt: String, runNumber: Int64?) {
        self.check = check
        self.identity = identity
        self.startedAt = startedAt
        self.runNumber = runNumber
    }
}
