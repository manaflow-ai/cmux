public import Foundation

/// Browser profiles that keep nothing on disk: the store of an incognito
/// window (plans/cmux-next/data-model.md, section 5). One profile id names
/// one off-the-record session in every engine: WebKit gives it a
/// non-persistent data store, Chromium an in-memory request context, site
/// settings an in-memory store. `end` tells every engine to drop it, which
/// deletes its data (cookies, caches, storage, permissions).
///
/// The App constructs one (`BrowserSharedStores`) and passes it by `init` to
/// both engines and every store, so all read the same answer to "is this
/// profile off the record". A second instance would answer no for an
/// incognito profile, and its data would go to disk.
public final class OffTheRecordProfiles {

    /// Profiles begun and not ended yet.
    public private(set) var active: Set<BrowserProfileID> = []
    /// Profiles that ended. A page or store still asking for one after its
    /// end must never get a persistent store.
    private var ended: Set<BrowserProfileID> = []
    private var endObservers: [(BrowserProfileID) -> Void] = []

    public init() {}

    /// A new off-the-record profile.
    public func begin() -> BrowserProfileID {
        let profile = BrowserProfileID(rawValue: UUID())
        active.insert(profile)
        return profile
    }

    /// True while `profile` is active.
    public func contains(_ profile: BrowserProfileID) -> Bool {
        active.contains(profile)
    }

    /// True when `profile` is or was off the record: stores use this, so a
    /// late request for an ended profile still gets an in-memory store.
    public func isOffTheRecord(_ profile: BrowserProfileID) -> Bool {
        active.contains(profile) || ended.contains(profile)
    }

    /// Ends `profile`: every engine drops its data. Close its pages first.
    public func end(_ profile: BrowserProfileID) {
        guard active.remove(profile) != nil else { return }
        ended.insert(profile)
        for observer in endObservers { observer(profile) }
    }

    /// Runs `observer` after each profile ends (engines drop their stores).
    public func observeEnd(_ observer: @escaping (BrowserProfileID) -> Void) {
        endObservers.append(observer)
    }
}
