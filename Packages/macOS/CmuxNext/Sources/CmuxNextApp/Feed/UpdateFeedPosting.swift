import CmuxNextCompat
import CmuxNextFeed
import CmuxNextUpdater
import Foundation

/// Installed updates in the Feed (Leo 2026-10-20): the first launch of a new cmux version posts
/// one notice with the version it came from, its top changes and the rest's count, built from the
/// same `UpdateHighlights` the Updated card shows. The card is posted once per version on this
/// Mac (``UpdateFeedPosting/postedKey``): the local feed owner is in memory, so without the record
/// every launch would post it again and mark it unread. Agent CLI updates post the same card
/// (`UpdateFeedCard.Subject.harness`) through ``FeedService/post(update:)``.
@MainActor
enum UpdateFeedPosting {
    /// The last app version whose card was posted (UserDefaults).
    static let postedKey = "cmux.feed.updateCard.postedVersion"

    /// The card for `highlights`, or nil when it has no changes to list yet (its notes are still
    /// loading) or names no update (the version it came from is this one).
    static func card(for highlights: UpdateHighlights, at: Date) -> UpdateFeedCard? {
        let changes = (highlights.items + (highlights.rest ?? [])).map(\.title).filter { !$0.isEmpty }
        guard !changes.isEmpty, highlights.fromVersion != highlights.version else { return nil }
        return UpdateFeedCard(subject: .app, from: highlights.fromVersion.isEmpty ? nil : highlights.fromVersion,
                              to: highlights.version, changes: changes, at: at)
    }

    /// Follows the Updated card's highlights and posts the card once they list changes.
    static func follow(_ services: AppServices, defaults: UserDefaults = .standard) -> Task<Void, Never> {
        let updater = services.updater
        // task-owner: AppServices.updateFeedObservation: ends after the one post, or with the services.
        return Task { [weak services] in
            for await highlights in ObservationStream({ updater.lastUpdateHighlights ?? updater.updatedWithoutRecordHighlights }) {
                guard let services, let highlights else { continue }
                guard defaults.string(forKey: postedKey) != highlights.version else { return }
                guard let card = card(for: highlights, at: Date()) else { continue }
                services.feed.post(update: card)
                defaults.set(highlights.version, forKey: postedKey)
                return
            }
        }
    }

    /// Debug: a sample cmux card and a sample Claude Code card, posted at once whatever was posted
    /// before (`debug.updater {action: "feedCards"}`).
    static func postSamples(_ services: AppServices) -> Int {
        let version = services.updater.identity.shortVersion
        let highlights = UpdateHighlights(version: version, build: services.updater.identity.build, fromVersion: "1.0.0-nightly.1",
                                          fromBuild: "", notes: .debugFake(version: version, changes: 6), appcast: nil)
        var posted = 0
        if let card = card(for: highlights, at: Date()) {
            services.feed.post(update: card)
            posted += 1
        }
        services.feed.post(update: UpdateFeedCard(
            subject: .harness(id: "claude", name: "Claude Code"), from: "2.1.303", to: "2.1.305",
            changes: ["Faster startup when many MCP servers are configured", "Fixed a hang when a hook printed a large output",
                      "`/model` lists the models your plan includes"],
            notes: URL(string: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"), at: Date()))
        return posted + 1
    }
}
