import Foundation

/// The what's-new card (R114): only on the first launch of a new build that
/// has human highlights, never on a fresh install.
extension UpdaterService {
    static let lastSeenBuildKey = "cmux.next.updates.lastSeenBuild"

    /// Runs once per launch: records this build as seen, and on an update to
    /// it loads its verified notes for the card.
    @discardableResult
    public func loadWhatsNew() -> Task<Void, Never>? {
        let build = identity.build
        let lastSeen = defaults.string(forKey: Self.lastSeenBuildKey)
        defaults.set(build, forKey: Self.lastSeenBuildKey)
        // A fresh install has seen nothing: not an update, no card.
        guard let lastSeen, lastSeen != build else { return nil }
        let load = notesLoader ?? { [releaseNotes] build in await releaseNotes?.notes(for: build) }
        return Task { [weak self] in
            let notes = await load(build)
            guard let self, WhatsNew.shows(currentBuild: build, lastSeenBuild: lastSeen, notes: notes) else { return }
            self.whatsNew = notes
            self.log.append("what's new: \(build) (updated from \(lastSeen))")
        }
    }

    /// The card's x or a click that opened the changelog.
    public func dismissWhatsNew() {
        whatsNew = nil
    }

    /// The card's text: title, the first highlight, and the open button.
    public var whatsNewCardText: (title: String, detail: String?)? {
        guard let whatsNew else { return nil }
        return (UpdaterStrings.whatsNewTitle(whatsNew.shortVersion), whatsNew.highlights.first?.title)
    }
}
