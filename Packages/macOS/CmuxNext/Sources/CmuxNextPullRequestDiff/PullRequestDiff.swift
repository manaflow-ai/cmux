public import CmuxNextAgentPane
public import Foundation

/// A pull request's Files tab (Session Info's View diff, a `/pull/N/files` link in a reply): its
/// diff opens in the diff viewer, no page in between (Leo, 2026-11-05: "you want to see the diff?
/// Boom, here's a diff"). The diff is read from the pull request's commits on this Mac when a chat
/// folder has them (``GitHubLocalDiff``), else from GitHub (`gh pr diff`); a diff that could not be
/// read opens the Files tab's web page.
public struct PullRequestDiff: Sendable {
    private let local: GitHubLocalDiff?
    private let read: @Sendable (URL) async -> String?

    /// `local`: this Mac's commits, tried first; `read`: GitHub's diff of a pull request address
    /// (`AgentChatPullRequestReader().diff(url:)`).
    public init(local: GitHubLocalDiff?, read: @escaping @Sendable (URL) async -> String?) {
        self.local = local
        self.read = read
    }

    /// Opens `link`'s diff through `openDiff`, or its Files tab's web page through `openWeb`.
    @MainActor
    public func open(_ link: GitHubLink, openDiff: @escaping @MainActor (String) -> Void, openWeb: @escaping @MainActor (URL) -> Void) {
        let plan = local?.plan(link)
        // task-owner: one diff read per click; it opens the diff, or the web page when the read fails.
        Task { [local, read] in
            var text: String?
            if let local, let plan { text = await local.diff(plan) }
            if text == nil {
                // Detached: the read decodes up to 16 MB, never on the main thread.
                text = await Task.detached(priority: .userInitiated) { await read(link.url) }.value
            }
            if let text, text.hasPrefix("diff --git ") { openDiff(text) } else { openWeb(link.filesURL) }
        }
    }
}
