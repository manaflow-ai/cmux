public import Foundation

/// The browser stores both engines and the App share, constructed once by the App and passed by
/// `init` to each engine: one answer to "is this profile off the record", one site-permission
/// registry and one zoom-per-site table, so a decision made in one engine applies in the other.
///
/// Every store that keeps profile data asks the same ``OffTheRecordProfiles``: a second set would
/// answer "not off the record" for an incognito profile and write its data to disk. So the App
/// builds one ``application()`` set, and tests build an ``inMemory()`` set each.
///
/// ```swift
/// let stores = BrowserSharedStores.application()
/// let webKit = WebKitEngine(stores: stores)
/// let cef = CEFEngine(source: source, stores: stores, signInCallbacks: CEFSignInCallbacks())
/// ```
@MainActor
public final class BrowserSharedStores {
    /// The incognito profiles: begun and ended by the App, read by every store.
    public let offTheRecord: OffTheRecordProfiles
    /// Per-profile site permissions (``SiteSettingsRegistry``).
    public let siteSettings: SiteSettingsRegistry
    /// Zoom per site and profile (``SiteZoomLevels``).
    public let siteZoom: SiteZoomLevels

    /// Stores over `offTheRecord`.
    ///
    /// - Parameters:
    ///   - offTheRecord: The incognito profiles every store asks.
    ///   - siteSettings: Site permissions built over the same `offTheRecord`.
    ///   - siteZoom: Zoom levels built over the same `offTheRecord`.
    public init(offTheRecord: OffTheRecordProfiles, siteSettings: SiteSettingsRegistry, siteZoom: SiteZoomLevels) {
        self.offTheRecord = offTheRecord
        self.siteSettings = siteSettings
        self.siteZoom = siteZoom
    }

    /// The App's stores: site settings and zoom levels in files under Application Support (one per
    /// profile; an incognito profile keeps its own in memory).
    public static func application() -> BrowserSharedStores {
        let offTheRecord = OffTheRecordProfiles()
        return BrowserSharedStores(
            offTheRecord: offTheRecord,
            siteSettings: SiteSettingsRegistry(
                persistence: { profile in FileSitePermissionPersistence(fileURL: SiteSettingsRegistry.defaultFile(for: profile)) },
                offTheRecord: offTheRecord),
            siteZoom: SiteZoomLevels(directory: SiteZoomLevels.defaultDirectory(), offTheRecord: offTheRecord))
    }

    /// Stores that keep everything in memory (tests, a debug window): nothing reaches the person's
    /// files.
    public static func inMemory() -> BrowserSharedStores {
        let offTheRecord = OffTheRecordProfiles()
        return BrowserSharedStores(
            offTheRecord: offTheRecord,
            siteSettings: SiteSettingsRegistry(persistence: { _ in MemorySitePermissionPersistence() }, offTheRecord: offTheRecord),
            siteZoom: SiteZoomLevels(directory: nil, offTheRecord: offTheRecord))
    }
}
