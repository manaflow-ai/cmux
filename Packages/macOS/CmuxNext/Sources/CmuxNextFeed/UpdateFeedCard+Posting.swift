public import Foundation

extension UpdateFeedCard {
    /// The next step for one installed version's Feed notice.
    public enum PostingStep: Equatable {
        /// Publish the prepared card and remember its version.
        case post(UpdateFeedCard)
        /// Remember the disabled version without publishing a notice.
        case skip(version: String)
        /// This version has already been handled.
        case done
        /// Wait for the installed version, authoritative settings or release notes.
        case wait
    }

    /// Decides whether to publish an installed update, waiting until its setting is known.
    ///
    /// A disabled version counts as handled even while its release notes are loading, so
    /// enabling the setting later cannot publish a stale card. The card is prepared only
    /// when publication is enabled and this version has not been handled.
    /// - Parameters:
    ///   - version: The installed update's version, or nil before it is known.
    ///   - posted: The last version already handled by the Feed.
    ///   - enabled: The What's New setting, or nil before settings have loaded.
    ///   - card: Builds the card, or returns nil while its release notes are loading.
    public static func postingStep(version: String?, posted: String?, enabled: Bool?, card: () -> UpdateFeedCard?) -> PostingStep {
        guard let version else { return .wait }
        guard posted != version else { return .done }
        guard let enabled else { return .wait }
        guard enabled else { return .skip(version: version) }
        return card().map(PostingStep.post) ?? .wait
    }

    /// A sample agent update for the Feed's debug preview.
    /// - Parameter at: The preview's timestamp.
    public static func sampleHarness(at: Date) -> UpdateFeedCard {
        UpdateFeedCard(
            subject: .harness(id: "claude", name: "Claude Code"), from: "2.1.303", to: "2.1.305",
            changes: ["Faster startup when many MCP servers are configured", "Fixed a hang when a hook printed a large output",
                      "`/model` lists the models your plan includes"],
            unlisted: 4, notes: URL(string: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"), at: at)
    }
}
