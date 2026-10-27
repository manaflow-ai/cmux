public import CmuxNextWakeups
public import Foundation

/// The browser stores both engines and the App share, constructed once by the App and passed by
/// `init` to each engine: one answer to "is this profile off the record", one site-permission
/// registry and one zoom-per-site table, so a decision made in one engine applies in the other.
///
/// Every store that keeps profile data asks the same ``OffTheRecordProfiles``: a second set would
/// answer "not off the record" for an incognito profile and write its data to disk. So the App
/// builds one ``application(files:)`` set, and tests build an ``inMemory()`` set each.
///
/// ```swift
/// let stores = BrowserSharedStores.application(files: work)
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
    /// profile; an incognito profile keeps its own in memory). Each store reads and writes its files in its
    /// own sequence on `work`'s files lane, never on main or the cooperative pool (p08-startup-098); nothing
    /// is read before a profile's first question.
    ///
    /// - Parameter work: The app's blocking-work lanes.
    public static func application(files work: BackgroundWork) -> BrowserSharedStores {
        let offTheRecord = OffTheRecordProfiles()
        let permissions = work.sequence("browser.siteSettings")
        return BrowserSharedStores(
            offTheRecord: offTheRecord,
            siteSettings: SiteSettingsRegistry(
                persistence: { profile in
                    FilesLaneSitePermissionPersistence(fileURL: SiteSettingsRegistry.defaultFile(for: profile), files: permissions)
                },
                offTheRecord: offTheRecord),
            siteZoom: SiteZoomLevels(directory: SiteZoomLevels.defaultDirectory(), offTheRecord: offTheRecord,
                                     files: work.sequence("browser.siteZoom")))
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

/// One profile's site decisions in one JSON file, read and written in a files-lane sequence: a load after
/// a save reads what it wrote, and two saves never reorder.
nonisolated struct FilesLaneSitePermissionPersistence: SitePermissionPersistence {
    /// The profile's file.
    let fileURL: URL
    /// The sequence every site-settings file read and write runs in.
    let files: WorkSequence

    func load() async -> SitePermissionSnapshot {
        let fileURL = fileURL
        return (try? await files.run(.userVisible) { FileSitePermissionPersistence.read(fileURL) }) ?? SitePermissionSnapshot()
    }

    func save(_ snapshot: SitePermissionSnapshot) async {
        let fileURL = fileURL
        try? await files.run(.bestEffort, shutdown: .blockShutdown) { FileSitePermissionPersistence.write(snapshot, to: fileURL) }
    }
}
