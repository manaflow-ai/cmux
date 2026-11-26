import AppKit

/// About cmux lists what is in this build (Leo 2026-11-26: "hm do we display which prs go into which
/// nightly maybe that'd be useful per thing?"): the PRs this build's signed notes name, by area.
extension UpdaterService {
    /// Opens About cmux at once. This build's PRs join its credits when read (cache-first, once per
    /// launch): a panel still on screen is shown again with them, a later open has them.
    public func showAboutPanel(bundle: Bundle = .main) {
        presentAboutPanel(bundle: bundle)
        guard aboutPullRequests == nil, aboutPullRequestsTask == nil else { return }
        aboutPullRequestsTask = Task { [weak self] in
            guard let self else { return }
            let read = await self.currentBuildPullRequests()
            self.aboutPullRequests = read
            guard !read.isEmpty, Self.aboutPanelIsOpen else { return }
            self.presentAboutPanel(bundle: bundle)
        }
    }

    private func presentAboutPanel(bundle: Bundle) {
        let credits = AboutPanelCredits(bundle: bundle, pullRequests: aboutPullRequests).credits
        NSApp.orderFrontStandardAboutPanel(options: credits.map { [.credits: $0] } ?? [:])
    }

    /// AppKit's standard About panel (a private NSPanel subclass, "NSAboutPanel") is still on screen:
    /// a panel the person closed is not opened again.
    private static var aboutPanelIsOpen: Bool {
        NSApp.windows.contains { $0.isVisible && $0.className.contains("About") }
    }
}
