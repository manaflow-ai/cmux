public import Foundation
public import CmuxNextSettings
import CmuxNextDesign

/// Where a pull request link clicked in an agent chat opens (Leo, 2026-11-07: "you should be able
/// to have an option to, like, default open in normal GitHub.com if you want, optionally"): its
/// github.com page in a cmux tab while `browser.openPullRequestsInGitHubPage` is off (the default since
/// https://github.com/manaflow-ai/cmux/issues/40889), the GitHub page when on. Session Info's View diff
/// (a `/files` link) opens its diff either way.
public extension GitHubLink {
    /// The link the GitHub page opens for `url`, nil to leave it to its web page: the page is
    /// switched on (`native`, nil: Debug Settings `links.githubNativeViewer`), the cmux browser is on and
    /// `url` is a pull request link; then, unless `explicit` (the link menu's Open in cmux GitHub
    /// Page), the link rule keeps it in cmux and the setting picks the page (or it is a `/files` link).
    nonisolated static func page(for url: URL, routing: LinkRouting, explicit: Bool = false,
                                 native: Bool? = nil) -> GitHubLink? {
        guard native ?? GitHubViewerTunables.nativePullRequests.value, routing.browserEnabled, let link = GitHubLink(url) else { return nil }
        if explicit { return link }
        guard routing.target(for: url) == .cmuxBrowser, link.files || routing.pullRequestsInGitHubPage else { return nil }
        return link
    }

    /// For a chat's link menu (`LinkRouter.gitHubPage`): nil when the page never shows `url`, true
    /// when a click opens it there, false when a click opens its web page.
    nonisolated static func clickOpensPage(_ url: URL, routing: LinkRouting,
                                           native: Bool? = nil) -> Bool? {
        guard page(for: url, routing: routing, explicit: true, native: native) != nil else { return nil }
        return page(for: url, routing: routing, native: native) != nil
    }
}
