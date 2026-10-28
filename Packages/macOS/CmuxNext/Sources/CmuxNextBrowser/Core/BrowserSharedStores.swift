public import CmuxNextCompat
public import CmuxNextWakeups
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
/// let cef = CEFEngine(source: source, stores: stores, signInCallbacks: CEFSignInCallbacks(), input: inputTap)
/// ```
@MainActor
public final class BrowserSharedStores {
    /// The incognito profiles: begun and ended by the App, read by every store.
    public let offTheRecord: OffTheRecordProfiles
    /// Per-profile site permissions (``SiteSettingsRegistry``).
    public let siteSettings: SiteSettingsRegistry
    /// Zoom per site and profile (``SiteZoomLevels``).
    public let siteZoom: SiteZoomLevels
    /// The App's lanes, set with the engines' wiring: an engine's blocking system calls (a remembered
    /// HTTP sign-in's Keychain read and write) run on their system lane. Nil (tests): none run.
    public var lanes: (any MayBlockRunner)?
    /// The remembered HTTP sign-ins in memory (``RememberedSecretIndex``): a WebKit challenge it knows needs no
    /// Keychain call. ``loadRememberedSignIns(on:)`` lists the Keychain's items into it at launch.
    package let httpSignIns = RememberedSecretIndex<BrowserHTTPRememberedLogin>()
    /// Where ``httpSignIns`` is listed from: the Keychain for the App's stores, none in memory.
    private let httpCredentialStore: (any BrowserHTTPCredentialStoring)?

    /// Stores over `offTheRecord`.
    ///
    /// - Parameters:
    ///   - offTheRecord: The incognito profiles every store asks.
    ///   - siteSettings: Site permissions built over the same `offTheRecord`.
    ///   - siteZoom: Zoom levels built over the same `offTheRecord`.
    ///   - httpCredentialStore: Where the remembered HTTP sign-ins are listed from at launch; nil lists none.
    package init(offTheRecord: OffTheRecordProfiles, siteSettings: SiteSettingsRegistry, siteZoom: SiteZoomLevels,
                 httpCredentialStore: (any BrowserHTTPCredentialStoring)?) {
        self.offTheRecord = offTheRecord
        self.siteSettings = siteSettings
        self.siteZoom = siteZoom
        self.httpCredentialStore = httpCredentialStore
    }

    /// Stores over `offTheRecord`, listing no remembered HTTP sign-in.
    public convenience init(offTheRecord: OffTheRecordProfiles, siteSettings: SiteSettingsRegistry, siteZoom: SiteZoomLevels) {
        self.init(offTheRecord: offTheRecord, siteSettings: siteSettings, siteZoom: siteZoom, httpCredentialStore: nil)
    }

    /// Sets the App's lanes and lists the remembered HTTP sign-ins' accounts into ``httpSignIns`` on their system
    /// lane (one Keychain list, no secret), at launch: from then a page load whose server has none answers its
    /// sign-in challenge with no Keychain call.
    public func loadRememberedSignIns(on work: BackgroundWork) {
        lanes = work
        guard let store = httpCredentialStore else { return }
        let index = httpSignIns
        work.post(.bestEffort, mayBlock: .system) { index.listed(store.rememberedAccounts()) }
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
            siteZoom: SiteZoomLevels(directory: SiteZoomLevels.defaultDirectory(), offTheRecord: offTheRecord),
            httpCredentialStore: KeychainHTTPCredentialStore.standard)
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
