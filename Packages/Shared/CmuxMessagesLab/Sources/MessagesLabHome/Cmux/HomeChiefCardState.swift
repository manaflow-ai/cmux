import CmuxHomeCore
import Foundation

/// What Chief cards show from this Mac rather than from a message (cmux issue 25830): the sites its
/// Secure Store holds, so a sign-in card for one of them says Added. The host makes one, fills it
/// from the keychain off the main thread, and gives it to every Home transcript
/// (``MessagesLabHomeView/chiefCardState``); a change tells each transcript showing it directly.
@MainActor
public final class HomeChiefCardState {
    /// The Secure Store's sites, lowercased.
    public private(set) var storedSites: Set<String> = []
    private var observers: [WeakObserver] = []

    public init() {}

    /// The store's sites (a keychain read); shown cards redraw when they changed.
    public func setStoredSites(_ sites: some Sequence<String>) {
        let new = Set(sites.map { $0.lowercased() })
        guard new != storedSites else { return }
        storedSites = new
        changed()
    }

    /// One sign-in was saved.
    public func addStoredSite(_ site: String) {
        guard storedSites.insert(site.lowercased()).inserted else { return }
        changed()
    }

    /// `observer` hears each change while it lives (held weakly).
    func observe(_ observer: HomeChiefCardStateObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
        observers.append(WeakObserver(value: observer))
    }

    func stopObserving(_ observer: HomeChiefCardStateObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
    }

    private func changed() {
        observers.removeAll { $0.value == nil }
        for observer in observers { observer.value?.chiefCardStateChanged() }
    }

    private struct WeakObserver {
        weak var value: HomeChiefCardStateObserver?
    }
}

/// A transcript that redraws its cards when ``HomeChiefCardState`` changes.
@MainActor
protocol HomeChiefCardStateObserver: AnyObject {
    func chiefCardStateChanged()
}
