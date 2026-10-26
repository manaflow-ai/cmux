import CmuxNextCompat
import CmuxNextFeed
import CmuxNextUpdater
import CmuxNextWakeups
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
    /// loading) or names no update (the version it came from is this one). A record saved before
    /// `rest` existed counts the changes it left out (`moreCount`).
    static func card(for highlights: UpdateHighlights, at: Date) -> UpdateFeedCard? {
        let listed = highlights.items + (highlights.rest ?? [])
        let changes = listed.map(\.title).filter { !$0.isEmpty }
        guard !changes.isEmpty, highlights.fromVersion != highlights.version else { return nil }
        return UpdateFeedCard(subject: .app, from: highlights.fromVersion.isEmpty ? nil : highlights.fromVersion,
                              to: highlights.version, changes: changes, unlisted: highlights.rest == nil ? highlights.moreCount : 0, at: at)
    }

    /// What one look at the highlights does: post this card, stop (this version's card was
    /// posted already), or wait for the highlights to list changes.
    enum Step: Equatable {
        case post(UpdateFeedCard)
        case done
        case wait
    }

    static func step(_ highlights: UpdateHighlights?, posted: String?, at: Date) -> Step {
        guard let highlights else { return .wait }
        guard posted != highlights.version else { return .done }
        return card(for: highlights, at: at).map(Step.post) ?? .wait
    }

    /// The highlights the card is built from on this look: the Updated card's while it shows. Its x
    /// clears them, maybe before this build's notes load; the Feed keeps what the card showed and
    /// lists the notes' changes once they arrive.
    static func highlights(_ updater: UpdaterService, held: UpdateHighlights?) -> UpdateHighlights? {
        if let shown = updater.lastUpdateHighlights ?? updater.updatedWithoutRecordHighlights { return shown }
        guard let held, held.items.isEmpty, let notes = updater.currentBuildNotes else { return held }
        return UpdateHighlights(version: held.version, build: held.build, fromVersion: held.fromVersion, fromBuild: held.fromBuild,
                                notes: notes, appcast: nil)
    }

    /// The highlights an earlier look saw (``highlights(_:held:)``), and whether the follow is over.
    @MainActor final class Held {
        var highlights: UpdateHighlights?
        var finished = false
        /// The follow's observation once made, so a later post ends it.
        weak var observation: ServiceObservation<UpdateHighlights?>?

        func finish() {
            finished = true
            observation?.cancel()
        }
    }

    /// Follows the Updated card's highlights and posts the card once they list changes. On a
    /// launch with no update it waits with the services (an update record only appears at launch,
    /// so it never posts then). A service observation (the post writes the feed and the defaults,
    /// whatever shows) in the background class: nobody waits on the card. It stops after the one
    /// post, or when the services release it (`AppServices.updateFeedObservation`).
    static func follow(_ services: AppServices, defaults: UserDefaults = .standard) -> ServiceObservation<UpdateHighlights?> {
        let updater = services.updater
        let held = Held()
        let observation = ServiceObservation(.background, owner: "UpdateFeedPosting.follow", on: services.mainWork) {
            Self.highlights(updater, held: held.highlights)
        } apply: { [weak services] highlights in
            guard let services, !held.finished else { return }
            held.highlights = highlights
            switch step(highlights, posted: defaults.string(forKey: postedKey), at: Date()) {
            case .wait: return
            case .done: held.finish()
            case let .post(card):
                services.feed.post(update: card)
                defaults.set(card.to, forKey: postedKey)
                held.finish()
            }
        }
        // The first look, in the init, may have finished already.
        if held.finished { observation.cancel() } else { held.observation = observation }
        return observation
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
            unlisted: 4, notes: URL(string: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"), at: Date()))
        return posted + 1
    }
}
