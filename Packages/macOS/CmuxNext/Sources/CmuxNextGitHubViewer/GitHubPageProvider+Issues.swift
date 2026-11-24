import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// The GitHub page's issue ops (`issues.list`, `issue.details`): thin glue over the GitHub host op.
/// GitHub's REST fields pass through as GitHub names them; only the ones the page draws are kept, and
/// pull requests (which GitHub's issues endpoint also lists) are left out.
extension GitHubPageProvider {
    /// The fields of an issue the page draws.
    nonisolated static let issueFields = ["number", "title", "state", "state_reason", "comments", "created_at", "updated_at",
                                          "html_url", "body"]
    /// The fields of a comment the page draws.
    nonisolated static let commentFields = ["body", "created_at", "html_url"]

    /// `{repo}` → `{issues}`: the repository's issues, newest activity first.
    func listIssues(_ params: JSONValue) async throws -> JSONValue {
        guard let repo = params["repo"]?.stringValue, Self.isRepository(repo) else {
            throw PageError.invalidParams("cmux.github.issues.list needs an owner/name repository")
        }
        let answer = await restGet(repo, "issues?state=all&per_page=50&sort=updated")
        try Task.checkCancellation()
        guard answer.ok, let list = Self.array(answer.body) else {
            throw PageError(code: "cmux.github.issues_unavailable", message: answer.refusal, retryable: true)
        }
        return ["issues": .array(Self.issues(list))]
    }

    /// `{url}` (a github.com issue) → `{issue, comments}`.
    func issueDetails(_ params: JSONValue) async throws -> JSONValue {
        guard let url = params["url"]?.stringValue, let (repo, number) = Self.issue(url) else {
            throw PageError.invalidParams("cmux.github.issue.details needs a github.com issue address")
        }
        let get = restGet
        async let issueAnswer = get(repo, "issues/\(number)")
        async let commentsAnswer = get(repo, "issues/\(number)/comments?per_page=100")
        let (issue, comments) = await (issueAnswer, commentsAnswer)
        try Task.checkCancellation()
        guard let object = issue.object, object["pull_request"] == nil else {
            throw PageError(code: "cmux.github.issue_unavailable", message: issue.refusal, retryable: true)
        }
        // The issue without its comments still draws; the page says there are more on GitHub.
        let shown = comments.ok ? (Self.array(comments.body) ?? []) : []
        return ["issue": Self.shapeIssue(object),
                "comments": .array(shown.compactMap { ($0 as? [String: Any]).map(Self.shapeComment) })]
    }

    /// GitHub's issues answer, pull requests left out, each issue shaped for the page.
    nonisolated static func issues(_ list: [Any]) -> [JSONValue] {
        list.compactMap { $0 as? [String: Any] }.filter { $0["pull_request"] == nil }.map(shapeIssue)
    }

    nonisolated static func shapeIssue(_ object: [String: Any]) -> JSONValue {
        var shaped = pick(object, issueFields)
        shaped["labels"] = (object["labels"] as? [Any] ?? []).compactMap { label -> Any? in
            // A label is an object (`{name, color}`) or, in older answers, just its name.
            if let name = label as? String { return ["name": name] }
            guard let label = label as? [String: Any], let name = label["name"] as? String else { return nil }
            return pick(label, ["color"]).merging(["name": name]) { $1 }
        }
        shaped["user"] = login(object["user"])
        return JSONValue(foundation: shaped) ?? .null
    }

    nonisolated static func shapeComment(_ object: [String: Any]) -> JSONValue {
        var shaped = pick(object, commentFields)
        shaped["user"] = login(object["user"])
        return JSONValue(foundation: shaped) ?? .null
    }

    /// `https://github.com/OWNER/NAME/issues/N` → (`OWNER/NAME`, N); nil for any other address.
    nonisolated static func issue(_ url: String) -> (repository: String, number: Int)? {
        guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host?.lowercased() == "github.com",
              parsed.query == nil, parsed.fragment == nil else { return nil }
        let parts = parsed.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[2] == "issues", let number = Int(parts[3]), number > 0 else { return nil }
        let repository = "\(parts[0])/\(parts[1])"
        return isRepository(repository) ? (repository, number) : nil
    }

    /// `OWNER/NAME`, each part GitHub's letters, digits, `-`, `_` and `.`.
    nonisolated static func isRepository(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
    }

    private nonisolated static func array(_ body: Data) -> [Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [Any]
    }

    private nonisolated static func pick(_ object: [String: Any], _ keys: [String]) -> [String: Any] {
        var picked: [String: Any] = [:]
        for key in keys { if let value = object[key], !(value is NSNull) { picked[key] = value } }
        return picked
    }

    private nonisolated static func login(_ user: Any?) -> Any {
        guard let login = (user as? [String: Any])?["login"] as? String else { return NSNull() }
        return ["login": login]
    }
}
