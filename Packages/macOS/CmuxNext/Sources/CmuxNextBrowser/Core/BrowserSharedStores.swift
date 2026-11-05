public import CmuxNextCompat
public import Foundation

/// The browser stores both engines and the App share, constructed once by the App and passed by
/// `init` to each engine: one answer to "is this profile off the record", one site-permission
/// registry and one zoom-per-site table, so a decision made in one engine applies in the other.
///
/// Every store that keeps profile data asks the same ``OffTheRecordProfiles``: a second set would
/// answer "not off the record" for an incognito profile and write its data to disk. So the App
/// builds one ``application(loginKeychain:)`` set, and tests build an ``inMemory()`` set each.
///
/// ```swift
/// let stores = BrowserSharedStores.application(loginKeychain: loginKeychain)
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
    /// HTTP sign-ins the user chose to remember (the WebKit engine's).
    package let httpCredentials: any BrowserHTTPCredentialStoring

    /// Stores over `offTheRecord`.
    ///
    /// - Parameters:
    ///   - offTheRecord: The incognito profiles every store asks.
    ///   - siteSettings: Site permissions built over the same `offTheRecord`.
    ///   - siteZoom: Zoom levels built over the same `offTheRecord`.
    ///   - httpCredentials: Remembered HTTP sign-ins.
    package init(offTheRecord: OffTheRecordProfiles, siteSettings: SiteSettingsRegistry, siteZoom: SiteZoomLevels,
                 httpCredentials: any BrowserHTTPCredentialStoring) {
        self.offTheRecord = offTheRecord
        self.siteSettings = siteSettings
        self.siteZoom = siteZoom
        self.httpCredentials = httpCredentials
    }

    /// The App's stores: site settings and zoom levels in files under Application Support (one per
    /// profile; an incognito profile keeps its own in memory), HTTP sign-ins in the Keychain behind
    /// the app's one `loginKeychain`.
    public static func application(loginKeychain: LoginKeychain) -> BrowserSharedStores {
        let offTheRecord = OffTheRecordProfiles()
        return BrowserSharedStores(
            offTheRecord: offTheRecord,
            siteSettings: SiteSettingsRegistry(
                persistence: { profile in FileSitePermissionPersistence(fileURL: SiteSettingsRegistry.defaultFile(for: profile)) },
                offTheRecord: offTheRecord),
            siteZoom: SiteZoomLevels(directory: SiteZoomLevels.defaultDirectory(), offTheRecord: offTheRecord),
            httpCredentials: KeychainHTTPCredentialStore.standard(loginKeychain: loginKeychain))
    }

    /// Stores that keep everything in memory (tests, a debug window): nothing reaches the person's
    /// files or Keychain.
    public static func inMemory() -> BrowserSharedStores {
        let offTheRecord = OffTheRecordProfiles()
        return BrowserSharedStores(
            offTheRecord: offTheRecord,
            siteSettings: SiteSettingsRegistry(persistence: { _ in MemorySitePermissionPersistence() }, offTheRecord: offTheRecord),
            siteZoom: SiteZoomLevels(directory: nil, offTheRecord: offTheRecord),
            httpCredentials: ForgettingHTTPCredentialStore())
    }
}
