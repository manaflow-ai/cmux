public import Foundation
public import CmuxNextSettings
import CmuxNextAgentPane

/// What the GitHub page draws beyond the link card's fields (Leo, 2026-11-07: the description and
/// the comments themselves near the top): the pull request's body, its conversation (comments and
/// reviews with their review comments, in time order), its reviewers, the issues it closes, its
/// labels with their colours, its head commit and GitHub's merge state. One `gh api graphql` read
/// per pull request, which the provider keeps until its `updatedAt` moves
/// (``GitHubPageProvider``), so a shown page refreshing every minute is not a read every minute.
public nonisolated struct GitHubPullRequestDetails: Equatable, Sendable {
    public struct Label: Equatable, Sendable {
        public var name: String
        /// GitHub's six hex digits, empty when it gave none.
        public var color: String
    }

    /// One review comment, on a line of a file.
    public struct ReviewComment: Equatable, Sendable {
        public var path: String
        public var line: Int?
        public var body: String
        /// GitHub's own rendering of `body` (``html(_:)``), empty when it is too long to send whole.
        public var html: String = ""
        public var url: String?
        /// Whether its thread is resolved; nil when the read did not reach its thread.
        public var resolved: Bool?
    }

    /// A comment or a review, by its author, in the conversation.
    public struct Entry: Equatable, Sendable {
        /// `comment` or `review`.
        public var kind: String
        public var author: String
        public var body: String
        /// GitHub's own rendering of `body` (``html(_:)``), empty when it is too long to send whole.
        public var html: String = ""
        /// GitHub's ISO 8601 text.
        public var at: String
        public var url: String?
        /// A review's verdict, lowercased: `approved`, `changes_requested`, `commented`, `dismissed`.
        public var state: String?
        public var comments: [ReviewComment] = []
    }

    public struct Reviewer: Equatable, Sendable {
        public var name: String
        /// `approved`, `changes_requested`, `commented`, `dismissed`, or `requested` (asked, not yet reviewed).
        public var state: String
    }

    /// An issue the pull request closes.
    public struct Linked: Equatable, Sendable {
        public var number: Int
        public var title: String
        public var url: String
        /// `open` or `closed`.
        public var state: String
    }

    public var body: String
    /// GitHub's own rendering of `body` (``html(_:)``), empty when it is too long to send whole.
    public var html: String = ""
    /// The head commit the page shows, the one its Merge is pinned to.
    public var headCommit: String
    /// GitHub's `mergeStateStatus`, lowercased (`clean`, `unstable`, `blocked`, `behind`, `dirty`, …).
    public var mergeState: String
    /// The user's default merge method for the repository: `merge`, `squash` or `rebase`.
    public var mergeMethod: String
    public var labels: [Label]
    public var conversation: [Entry]
    /// How many comments and reviews GitHub has, which can be more than `conversation` holds.
    public var conversationTotal: Int
    public var reviewers: [Reviewer]
    public var linked: [Linked]
    /// The signed-in person's GitHub login (the page's "Mine"), empty when the read did not say.
    public var viewer: String = ""

    static let maximumComments = 50
    static let maximumReviews = 30
    static let maximumReviewComments = 30
    static let maximumThreads = 100
    static let maximumBody = 64_000
    static let maximumCommentBody = 20_000
    /// GitHub's HTML of a body is longer than its Markdown (its links, its image proxy's URLs); past
    /// this it is dropped, never cut, since a cut tag breaks the markup, and the page draws the text.
    static let maximumHTML = 160_000
    /// All the HTML one read sends. Past it, a body's HTML is dropped (it draws its Markdown): the
    /// description's first, then the newest entries', so one pull request's reply stays bounded.
    static let maximumTotalHTML = 1_000_000

    /// GraphQL's non-null mark, spelled apart so the crash ratchet does not read it as an unwrap.
    private static let required = "!"
    /// The read, with the pull request's owner, name and number as variables.
    static let query = """
        query($owner: String\(required), $name: String\(required), $number: Int\(required)) { viewer { login } repository(owner: $owner, name: $name) {
          viewerDefaultMergeMethod
          pullRequest(number: $number) { body bodyHTML headRefOid mergeStateStatus
            labels(first: 20) { nodes { name color } }
            comments(last: \(maximumComments)) { totalCount nodes { author { login } body bodyHTML createdAt url } }
            reviews(last: \(maximumReviews)) { totalCount nodes { author { login } state body bodyHTML submittedAt url
              comments(first: \(maximumReviewComments)) { nodes { path line originalLine body bodyHTML url } } } }
            reviewRequests(first: 20) { nodes { requestedReviewer { __typename ... on User { login } ... on Team { name } ... on Bot { login } } } }
            latestOpinionatedReviews(first: 20) { nodes { author { login } state } }
            reviewThreads(last: \(maximumThreads)) { nodes { isResolved comments(first: \(maximumReviewComments)) { nodes { url } } } }
            closingIssuesReferences(first: 10) { nodes { number title url state } } } } }
        """

    /// The `gh api graphql` arguments for `link`; owner and name go as raw strings (`-f`), so
    /// neither is read as a file.
    static func arguments(for link: GitHubLink) -> [String] {
        let parts = link.repository.split(separator: "/").map(String.init)
        return ["api", "graphql", "--hostname", "github.com", "-f", "owner=\(parts.first ?? "")", "-f", "name=\(parts.last ?? "")",
                "-F", "number=\(link.number)", "-f", "query=\(query)"]
    }

    /// Reads `link`'s details with the user's gh; nil when gh is missing, fails or answers no pull request.
    @concurrent public static func read(_ link: GitHubLink) async -> GitHubPullRequestDetails? {
        guard let data = await AgentPaneGitPullRequest.pageRead(arguments(for: link)) else { return nil }
        return parse(data)
    }

    /// The details in a `gh api graphql` answer, nil when it is not one.
    static func parse(_ data: Data) -> GitHubPullRequestDetails? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let repository = (object["data"] as? [String: Any])?["repository"] as? [String: Any],
              let pull = repository["pullRequest"] as? [String: Any] else { return nil }
        let nodes = { (key: String, object: [String: Any]) in ((object[key] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] }
        let total = { (key: String) in ((pull[key] as? [String: Any])?["totalCount"] as? Int) ?? 0 }
        let login = { (node: [String: Any]) in ((node["author"] as? [String: Any])?["login"] as? String) ?? "" }
        let text = { (value: Any?, limit: Int) in String((value as? String ?? "").prefix(limit)) }
        let html = { (node: [String: Any]) in Self.html(node["bodyHTML"]) }
        // Each review comment's thread state, by the comment's link.
        var resolved: [String: Bool] = [:]
        for thread in nodes("reviewThreads", pull) {
            let state = thread["isResolved"] as? Bool ?? false
            for comment in nodes("comments", thread) {
                if let url = link(comment["url"]) { resolved[url] = state }
            }
        }
        let comments = nodes("comments", pull).map { node in
            Entry(kind: "comment", author: login(node), body: text(node["body"], maximumCommentBody), html: html(node),
                  at: node["createdAt"] as? String ?? "", url: link(node["url"]))
        }
        let reviews = nodes("reviews", pull).compactMap { node -> Entry? in
            let inline = nodes("comments", node).prefix(maximumReviewComments).compactMap { comment -> ReviewComment? in
                guard let path = comment["path"] as? String, !path.isEmpty else { return nil }
                return ReviewComment(path: path, line: (comment["line"] as? Int) ?? (comment["originalLine"] as? Int),
                                     body: text(comment["body"], maximumCommentBody), html: html(comment), url: link(comment["url"]),
                                     resolved: link(comment["url"]).flatMap { resolved[$0] })
            }
            let body = text(node["body"], maximumCommentBody)
            let state = (node["state"] as? String)?.lowercased() ?? "commented"
            // A bare "commented" review with nothing in it (a pending one, a reply's wrapper) says nothing.
            if state == "commented", body.isEmpty, inline.isEmpty { return nil }
            if state == "pending" { return nil }
            return Entry(kind: "review", author: login(node), body: body, html: html(node), at: node["submittedAt"] as? String ?? "",
                         url: link(node["url"]), state: state, comments: Array(inline))
        }
        // ISO 8601 in UTC sorts as text.
        var budget = maximumTotalHTML
        let description = spend(html(pull), &budget)
        let conversation = Array((comments + reviews).sorted { $0.at < $1.at }.reversed().map { entry -> Entry in
            var entry = entry
            entry.html = spend(entry.html, &budget)
            entry.comments = entry.comments.map { comment in
                var comment = comment
                comment.html = spend(comment.html, &budget)
                return comment
            }
            return entry
        }.reversed())
        var reviewers = nodes("latestOpinionatedReviews", pull).compactMap { node -> Reviewer? in
            let name = login(node)
            return name.isEmpty ? nil : Reviewer(name: name, state: (node["state"] as? String)?.lowercased() ?? "commented")
        }
        for node in nodes("reviewRequests", pull) {
            let reviewer = node["requestedReviewer"] as? [String: Any]
            let name = (reviewer?["login"] as? String) ?? (reviewer?["name"] as? String) ?? ""
            // A re-request after a review: the person is asked again, so the row says so.
            reviewers.removeAll { $0.name == name }
            if !name.isEmpty { reviewers.append(Reviewer(name: name, state: "requested")) }
        }
        let linked = nodes("closingIssuesReferences", pull).compactMap { node -> Linked? in
            guard let number = node["number"] as? Int, let url = link(node["url"]) else { return nil }
            return Linked(number: number, title: text(node["title"], 500), url: url, state: (node["state"] as? String)?.lowercased() ?? "")
        }
        let labels = nodes("labels", pull).compactMap { node -> Label? in
            guard let name = node["name"] as? String, !name.isEmpty else { return nil }
            let color = (node["color"] as? String) ?? ""
            return Label(name: name, color: color.count == 6 && color.allSatisfy(\.isHexDigit) ? color.lowercased() : "")
        }
        let method = (repository["viewerDefaultMergeMethod"] as? String)?.lowercased() ?? ""
        return GitHubPullRequestDetails(
            body: text(pull["body"], maximumBody), html: description, headCommit: (pull["headRefOid"] as? String) ?? "",
            mergeState: (pull["mergeStateStatus"] as? String)?.lowercased() ?? "",
            mergeMethod: ["merge", "squash", "rebase"].contains(method) ? method : "merge",
            labels: labels, conversation: conversation, conversationTotal: total("comments") + total("reviews"),
            reviewers: reviewers, linked: linked,
            viewer: ((object["data"] as? [String: Any])?["viewer"] as? [String: Any])?["login"] as? String ?? "")
    }

    /// GitHub's rendering of a body (`bodyHTML`: its Markdown and the HTML GitHub allows, sanitized,
    /// images through GitHub's proxy), whole or not at all. The page parses it inertly and keeps only
    /// its own allowlist (webviews/src/pages/github/githubHTML.ts).
    static func html(_ value: Any?) -> String {
        guard let text = value as? String, text.utf8.count <= maximumHTML else { return "" }
        return text
    }

    /// `html` when the read's HTML budget still holds it whole (and less of the budget), else "".
    static func spend(_ html: String, _ budget: inout Int) -> String {
        let size = html.utf8.count
        guard size <= budget else { return "" }
        budget -= size
        return html
    }

    /// `value` when it is a github.com https link, the only kind the page opens.
    private static func link(_ value: Any?) -> String? {
        guard let text = value as? String, text.hasPrefix("https://github.com/"), !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }

    /// The page's shape of it (webviews/src/pages/github/types.ts `PullRequestDetails`).
    public var json: JSONValue {
        let optional = { (text: String?) in text.map(JSONValue.string) ?? .null }
        return .object([
            "body": .string(body), "html": .string(html), "headCommit": .string(headCommit), "mergeState": .string(mergeState),
            "mergeMethod": .string(mergeMethod), "conversationTotal": JSONValue(conversationTotal), "viewer": .string(viewer),
            "labels": .array(labels.map { .object(["name": .string($0.name), "color": .string($0.color)]) }),
            "conversation": .array(conversation.map { entry in
                .object(["kind": .string(entry.kind), "author": .string(entry.author), "body": .string(entry.body),
                         "html": .string(entry.html),
                         "at": .string(entry.at), "url": optional(entry.url), "state": optional(entry.state),
                         "comments": .array(entry.comments.map { comment in
                             .object(["path": .string(comment.path), "line": comment.line.map { JSONValue($0) } ?? .null,
                                      "body": .string(comment.body), "html": .string(comment.html), "url": optional(comment.url),
                                      "resolved": comment.resolved.map(JSONValue.bool) ?? .null])
                         })])
            }),
            "reviewers": .array(reviewers.map { .object(["name": .string($0.name), "state": .string($0.state)]) }),
            "linked": .array(linked.map { item in
                .object(["number": JSONValue(item.number), "title": .string(item.title), "url": .string(item.url),
                         "state": .string(item.state)])
            }),
        ])
    }
}
