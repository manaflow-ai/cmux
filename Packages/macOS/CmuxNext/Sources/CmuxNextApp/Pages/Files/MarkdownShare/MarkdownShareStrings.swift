import Foundation

/// The Markdown omnibar's Share menu and repo chip strings (table `FilePages`).
nonisolated enum MarkdownShareStrings {
    static var copyPath: String {
        String(localized: "markdownShare.copyPath", defaultValue: "Copy Path", table: "FilePages", bundle: .module)
    }

    static var copyGitHubLink: String {
        String(localized: "markdownShare.copyGitHubLink", defaultValue: "Copy GitHub Link", table: "FilePages", bundle: .module)
    }

    static var copyGitHubLinkLastPushed: String {
        String(localized: "markdownShare.copyGitHubLinkLastPushed", defaultValue: "Copy GitHub Link (Last Pushed Version)",
               table: "FilePages", bundle: .module)
    }

    static var noGitHubLink: String {
        String(localized: "markdownShare.noGitHubLink", defaultValue: "No GitHub Link: Commit and Push First", table: "FilePages", bundle: .module)
    }

    static var copyLiveLink: String {
        String(localized: "markdownShare.copyLiveLink", defaultValue: "Copy Local Live Link", table: "FilePages", bundle: .module)
    }

    static var openLiveLink: String {
        String(localized: "markdownShare.openLiveLink", defaultValue: "Open Live Link in Browser", table: "FilePages", bundle: .module)
    }

    static var revealInFinder: String {
        String(localized: "markdownShare.revealInFinder", defaultValue: "Reveal in Finder", table: "FilePages", bundle: .module)
    }

    static var liveShareLater: String {
        String(localized: "markdownShare.liveShareLater", defaultValue: "Live Share with Presence (Coming Later)", table: "FilePages", bundle: .module)
    }

    /// The repo chip's help for a file in `state`.
    static func state(_ state: MarkdownGitLocation.State) -> String {
        switch state {
        case .pushed:
            String(localized: "markdownShare.state.pushed", defaultValue: "Pushed: GitHub shows this version.", table: "FilePages", bundle: .module)
        case .unpushed:
            String(localized: "markdownShare.state.unpushed", defaultValue: "Committed, not pushed.", table: "FilePages", bundle: .module)
        case .modified:
            String(localized: "markdownShare.state.modified", defaultValue: "Uncommitted changes.", table: "FilePages", bundle: .module)
        case .untracked:
            String(localized: "markdownShare.state.untracked", defaultValue: "Not tracked by git.", table: "FilePages", bundle: .module)
        case .ignored:
            String(localized: "markdownShare.state.ignored", defaultValue: "Ignored by git.", table: "FilePages", bundle: .module)
        }
    }
}
