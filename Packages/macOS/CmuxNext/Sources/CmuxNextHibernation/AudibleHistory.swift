package import CmuxNextWakeups

/// When each piece of content last played sound, for ``DiscardRule/recentlyAudible`` (Chrome's
/// `kTabAudioProtectionTime`).
///
/// Chrome's page node keeps its audible bit and the time of its last change
/// (`PageNode::IsAudible`, `GetTimeSinceLastAudibleChange`,
/// components/performance_manager/public/graph/page_node.h). Here each watched source (a browser
/// page) is followed by a ``ServiceObservation`` of what `isAudible` reads, so nothing polls; a
/// change applies as one `background` task on the scheduler (nobody waits for it, and it runs for
/// hidden pages). `isAudible` must read a value that changes only when the sound starts or stops
/// (`BrowserAudibleReporting.isAudible`), as Chrome's `OnIsAudibleChanged` fires on the flip only.
/// The change that ends the sound records the time and calls ``onEnded`` once, so its owner
/// replans and the protection's end joins the planner's one deadline.
///
/// ```swift
/// let history = AudibleHistory(mainWork: mainWork)
/// history.onEnded = { key in hibernation.replan() }
/// history.watch(key, page) { [weak page] in page?.isAudible == true }
/// candidate.secondsSinceAudible = history.secondsSinceAudible(key)
/// ```
@MainActor
package final class AudibleHistory {
    private struct Watch {
        /// The source watched: another source under the same key (a restored page) is watched anew.
        weak var source: AnyObject?
        var audible: Bool
        /// Releasing it (a new source, unwatch, forget) stops its applies.
        var observation: ServiceObservation<Bool>?
    }

    private var heardAt: [String: ContinuousClock.Instant] = [:]
    private var watches: [String: Watch] = [:]
    private let now: () -> ContinuousClock.Instant
    private let work: MainWorkScheduler
    /// Content `key`'s sound ended (its owner replans).
    package var onEnded: (String) -> Void = { _ in }

    /// Makes an empty history.
    ///
    /// - Parameters:
    ///   - now: The clock reading (a seam for tests).
    ///   - mainWork: The app's one main-thread scheduler: a source's change applies on it.
    package init(now: @escaping () -> ContinuousClock.Instant = { .now }, mainWork: MainWorkScheduler) {
        self.now = now
        work = mainWork
    }

    /// Follows content `key`'s sound in `source` from now on: what `isAudible` reads is observed.
    /// Nothing when `source` is watched under `key` already.
    ///
    /// - Parameters:
    ///   - key: The content's key.
    ///   - source: The object that plays, compared by identity and held weakly.
    ///   - isAudible: Whether `source` plays sound now, read from a value that changes only when the
    ///     sound starts or stops; it holds `source` weakly too.
    package func watch(_ key: String, _ source: AnyObject, isAudible: @escaping @MainActor () -> Bool) {
        guard watches[key]?.source !== source else { return }
        arm(key, source, isAudible)
    }

    /// Content `key` was heard now by other means (a probe found sound: unmuted media or Web Audio).
    package func heard(_ key: String) {
        heardAt[key] = now()
    }

    /// Seconds since content `key` last played sound; nil when it never did.
    package func secondsSinceAudible(_ key: String) -> Double? {
        heardAt[key].map { (now() - $0).secondsValue }
    }

    /// Whether the watch of content `key` saw it play at its last change; nil when it is not watched.
    package func isWatchedAudible(_ key: String) -> Bool? {
        watches[key]?.audible
    }

    /// Stops watching content `key`'s current source (it was swapped for one that plays nothing);
    /// its history stays.
    package func unwatch(_ key: String) {
        watches[key] = nil
    }

    /// Drops content `key`'s watch and history (it closed).
    package func forget(_ key: String) {
        watches[key] = nil
        heardAt[key] = nil
    }

    private func arm(_ key: String, _ source: AnyObject, _ isAudible: @escaping @MainActor () -> Bool) {
        watches[key] = Watch(source: source, audible: false)
        // The init applies the value it reads now, in this turn; later changes apply on the scheduler.
        let observation = ServiceObservation(.background, owner: "hibernation.audible", on: work, read: isAudible) { [weak self] audible in
            self?.changed(key, audible: audible)
        }
        watches[key]?.observation = observation
    }

    private func changed(_ key: String, audible: Bool) {
        guard var watch = watches[key] else { return }
        guard watch.source != nil else {
            watches[key] = nil
            return
        }
        let wasAudible = watch.audible
        watch.audible = audible
        watches[key] = watch
        if audible || wasAudible { heardAt[key] = now() }
        if wasAudible, !audible { onEnded(key) }
    }
}

private extension Duration {
    var secondsValue: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
