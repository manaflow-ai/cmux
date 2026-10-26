import Observation

/// When each piece of content last played sound, for ``DiscardRule/recentlyAudible`` (Chrome's
/// `kTabAudioProtectionTime`).
///
/// Chrome's page node keeps its audible bit and the time of its last change
/// (`PageNode::IsAudible`, `GetTimeSinceLastAudibleChange`,
/// components/performance_manager/public/graph/page_node.h). Here each watched source (a browser
/// page) is followed with Observation on what `isAudible` reads, re-armed after each change, so
/// nothing polls. The change that ends the sound records the time and calls ``onEnded`` once, so its
/// owner replans and the protection's end joins the planner's one deadline.
///
/// ```swift
/// let history = AudibleHistory()
/// history.onEnded = { key in hibernation.replan() }
/// history.watch(key, tab) { [weak tab] in tab?.state.media?.isAudible == true }
/// candidate.secondsSinceAudible = history.secondsSinceAudible(key)
/// ```
@MainActor
package final class AudibleHistory {
    private struct Watch {
        /// The source watched: another source under the same key (a restored page) is armed anew.
        weak var source: AnyObject?
        var arming: Int
        var audible: Bool
    }

    private var heardAt: [String: ContinuousClock.Instant] = [:]
    private var watches: [String: Watch] = [:]
    private var armings = 0
    private let now: () -> ContinuousClock.Instant
    /// Content `key`'s sound ended (its owner replans).
    package var onEnded: (String) -> Void = { _ in }

    /// Makes an empty history.
    ///
    /// - Parameter now: The clock reading (a seam for tests).
    package init(now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    /// Follows content `key`'s sound in `source` from now on: what `isAudible` reads is observed.
    /// Nothing when `source` is watched under `key` already.
    ///
    /// - Parameters:
    ///   - key: The content's key.
    ///   - source: The object that plays, compared by identity and held weakly.
    ///   - isAudible: Whether `source` plays sound now; it holds `source` weakly too.
    package func watch(_ key: String, _ source: AnyObject, isAudible: @escaping @MainActor () -> Bool) {
        guard watches[key]?.source !== source else { return }
        arm(key, source, isAudible)
    }

    /// Content `key` was heard now by other means (a probe found media that plays).
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
        armings += 1
        let arming = armings
        let audible = withObservationTracking { isAudible() } onChange: { [weak self] in
            // task-owner: one hop per change of a watched source; it re-arms itself and ends with forget or unwatch
            Task { @MainActor [weak self] in
                guard let self, self.watches[key]?.arming == arming else { return }
                self.changed(key, isAudible)
            }
        }
        if audible { heardAt[key] = now() }
        watches[key] = Watch(source: source, arming: arming, audible: audible)
    }

    private func changed(_ key: String, _ isAudible: @escaping @MainActor () -> Bool) {
        guard let watch = watches[key], let source = watch.source else {
            watches[key] = nil
            return
        }
        arm(key, source, isAudible)
        guard watch.audible, watches[key]?.audible == false else { return }
        heardAt[key] = now()
        onEnded(key)
    }
}

private extension Duration {
    var secondsValue: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
