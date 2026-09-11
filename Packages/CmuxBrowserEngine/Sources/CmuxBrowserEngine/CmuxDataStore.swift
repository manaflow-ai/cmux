import Foundation
@preconcurrency import WebKit

/// Engine-neutral wrapper around a profile's website data store
/// (cookies, local storage, IndexedDB, service workers, etc.).
///
/// `WKWebsiteDataStore` maps to a single underlying instance per
/// `CmuxDataStore`. Multiple `CmuxBrowserView`s sharing the same
/// `CmuxDataStore` share their backing storage — that's the whole
/// point of profiles.
///
/// Construction:
///   * `.default()` — persistent default, shared with `WKWebView()`'s
///     default. Use for the built-in profile.
///   * `.nonPersistent()` — in-memory; cleared when no views reference
///     it. Use for incognito-style sessions.
///   * `.forIdentifier(_:)` — persistent per-UUID. Two stores with the
///     same UUID share storage across process restarts. Use for named
///     profiles created in Settings → Browser → Profiles.
///
/// Today the backing implementation is always `WKWebsiteDataStore`.
/// When the Chromium backend lands, a `CmuxDataStore` constructed via
/// the same factories will resolve to a Chromium `BrowserContext` keyed
/// off the same identifier so user profiles are stable across the
/// engine swap.
public final class CmuxDataStore: @unchecked Sendable {
    /// Identifies the kind of store. The Chromium backend uses this to
    /// pick between in-memory and on-disk `BrowserContext`s and to
    /// derive on-disk profile paths from the identifier.
    public enum Kind: Sendable, Hashable {
        case `default`
        case nonPersistent
        case persistent(identifier: UUID)
    }

    public let kind: Kind

    /// The underlying WebKit store. Backend-private; accessed by
    /// `WebKitBrowserBackend` when wiring `WKWebViewConfiguration`.
    /// Chromium backend will keep this `nil` and use its own mapping.
    let wkStore: WKWebsiteDataStore?

    /// Cached cookie store wrapper. Lazily created so callers don't pay
    /// the bridge cost until they ask for cookies.
    private var _cookieStore: CmuxCookieStore?

    @MainActor
    public var cookieStore: CmuxCookieStore {
        if let existing = _cookieStore { return existing }
        let made = CmuxCookieStore(wkStore: wkStore?.httpCookieStore)
        _cookieStore = made
        return made
    }

    private init(kind: Kind, wkStore: WKWebsiteDataStore?) {
        self.kind = kind
        self.wkStore = wkStore
    }

    @MainActor
    public static func `default`() -> CmuxDataStore {
        CmuxDataStore(kind: .default, wkStore: .default())
    }

    @MainActor
    public static func nonPersistent() -> CmuxDataStore {
        CmuxDataStore(kind: .nonPersistent, wkStore: .nonPersistent())
    }

    /// Persistent store keyed by `identifier`. Two stores constructed
    /// with the same UUID share on-disk storage. Mirrors
    /// `WKWebsiteDataStore(forIdentifier:)`.
    @MainActor
    public static func forIdentifier(_ identifier: UUID) -> CmuxDataStore {
        CmuxDataStore(
            kind: .persistent(identifier: identifier),
            wkStore: WKWebsiteDataStore(forIdentifier: identifier)
        )
    }

    /// Every known website-data type the engine can clear. Today this
    /// is `WKWebsiteDataStore.allWebsiteDataTypes()`. When Chromium
    /// lands we map these strings to Chromium's `BrowsingDataType` mask.
    @MainActor
    public static func allDataTypes() -> Set<String> {
        WKWebsiteDataStore.allWebsiteDataTypes()
    }

    /// Removes website data of the given types modified at or after
    /// `since`. Pass `Date.distantPast` to clear everything.
    @MainActor
    public func removeData(ofTypes types: Set<String>, modifiedSince since: Date) async {
        guard let wkStore else { return }
        await withCheckedContinuation { continuation in
            wkStore.removeData(ofTypes: types, modifiedSince: since) {
                continuation.resume()
            }
        }
    }
}
