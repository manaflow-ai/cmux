public import CmuxNextAgentPane
public import Foundation

/// A pull request's Files tab (Session Info's View diff, a `/pull/N/files` link in a reply): its
/// diff opens in the diff viewer through `openDiff`, no page in between (Leo, 2026-11-05: "you want
/// to see the diff? Boom, here's a diff"). It is read from the pull request's commits on this Mac
/// when a chat folder has them (``GitHubLocalDiff``), else from GitHub (`gh pr diff`); a diff that
/// could not be read opens the Files tab's web page.
public enum GitHubPullRequestDiff {
    @MainActor
    public static func openFiles(_ link: GitHubLink, localDiff: GitHubLocalDiff?, openDiff: @escaping @MainActor (String) -> Void,
                                 openWeb: @escaping @MainActor (URL) -> Void) {
        openFiles(link, localDiff: localDiff, read: { await AgentChatPullRequestReader().diff(url: $0) }, openDiff: openDiff, openWeb: openWeb)
    }

    /// ``openFiles(_:localDiff:openDiff:openWeb:)`` with GitHub's diff read by `read` (tests).
    @MainActor
    static func openFiles(_ link: GitHubLink, localDiff: GitHubLocalDiff?, read: @escaping @Sendable (URL) async -> String?,
                          openDiff: @escaping @MainActor (String) -> Void, openWeb: @escaping @MainActor (URL) -> Void) {
        let plan = localDiff?.plan(link), url = link.url
        // task-owner: one diff read per click; it opens the diff, or the web page when the read fails.
        Task { @MainActor in
            // Detached: the read decodes up to 16 MB, never on the main thread (the local read hops to it only to send).
            let text = await Task.detached(priority: .userInitiated) { () async -> String? in
                if let localDiff, let plan, let text = await localDiff.diff(plan) { return text }
                return await read(url)
            }.value
            if let text, text.hasPrefix("diff --git ") { openDiff(text) } else { openWeb(link.filesURL) }
        }
    }
}
