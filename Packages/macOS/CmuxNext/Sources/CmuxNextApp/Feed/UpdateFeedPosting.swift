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
    /// loading) or names no update (the version it came from is this one). A record saved before
    /// `rest` existed counts the changes it left out (`moreCount`).
    static func card(for highlights: UpdateHighlights, at: Date) -> UpdateFeedCard? {
        let listed = highlights.items + (highlights.rest ?? [])
        let changes = listed.map(\.title).filter { !$0.isEmpty }
        guard !changes.isEmpty, highlights.fromVersion != highlights.version else { return nil }
        return UpdateFeedCard(subject: .app, from: highlights.fromVersion.isEmpty ? nil : highlights.fromVersion,
                              to: highlights.version, changes: changes, unlisted: highlights.rest == nil ? highlights.moreCount : 0, at: at)
    }

    /// Applies the Feed's publication policy after adapting the updater's highlights.
    static func step(_ highlights: UpdateHighlights?, posted: String?, enabled: Bool? = true, at: Date) -> UpdateFeedCard.PostingStep {
        UpdateFeedCard.postingStep(version: highlights?.version, posted: posted, enabled: enabled) {
            highlights.flatMap { card(for: $0, at: at) }
        }
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

    /// The highlights an earlier look saw (``highlights(_:held:)``).
    @MainActor final class Held {
        var highlights: UpdateHighlights?
    }

    /// Follows the Updated card's highlights and posts the card once they list changes. On a
    /// launch with no update it waits with the services (an update record only appears at launch,
    /// so it never posts then).
    static func follow(_ services: AppServices, defaults: UserDefaults = .standard) -> Task<Void, Never> {
        let updater = services.updater
        let held = Held()
        // task-owner: AppServices.updateFeedObservation: ends after the one post, or with the services.
        return Task { [weak services] in
            // The setting is read inside the observed closure, so its first load re-runs the step.
            for await (highlights, enabled) in ObservationStream({
                (Self.highlights(updater, held: held.highlights), updater.whatsNew.isItemEnabledKnown ? updater.whatsNew.isItemEnabled : nil)
            }) {
                guard let services else { return }
                held.highlights = highlights
                switch step(highlights, posted: defaults.string(forKey: postedKey), enabled: enabled, at: Date()) {
                case .wait: continue
                case .done: return
                case let .skip(version):
                    defaults.set(version, forKey: postedKey)
                    return
                case let .post(card):
                    services.feed.post(update: card)
                    defaults.set(card.to, forKey: postedKey)
                    return
                }
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
        services.feed.post(update: .sampleHarness(at: Date()))
        return posted + 1
    }
}
