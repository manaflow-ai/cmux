public import CmuxNextDesign
import CmuxNextPages

/// The GitHub page's kill switch (Debug Settings `links.githubNativeViewer`). On: a pull request
/// link clicked in an agent chat may open the native GitHub page (``GitHubLink``, when
/// `browser.openPullRequestsInGitHubPage` is on); off: always its web page.
public nonisolated struct GitHubViewerTunables {
    public nonisolated init() {}
    public static let nativePullRequests = Tunable<Bool>.toggle(
        "links.githubNativeViewer", PageTunables.section, "Native GitHub pull request page",
        help: "A pull request link clicked in an agent chat opens cmux's own GitHub page, with Open on GitHub one click away. Off opens github.com.",
        default: true, code: "GitHubViewerTunables.nativePullRequests")

    public static var all: [TunableDescriptor] { [nativePullRequests.descriptor] }
}
