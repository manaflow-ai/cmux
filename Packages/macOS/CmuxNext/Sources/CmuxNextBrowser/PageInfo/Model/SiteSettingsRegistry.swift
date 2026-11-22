public import Foundation

/// Per-profile site settings for the process: one `SitePermissionStore` per
/// browser profile, shared by the WebKit and Chromium engines so a decision
/// made in one applies in both. Persisted like cmux.json settings (one file
/// per profile under Application Support), so it is process-wide, as
/// `DesignSettings.shared` is.
public final class SiteSettingsRegistry {
    public static let shared = SiteSettingsRegistry(
        persistence: { profile in FileSitePermissionPersistence(fileURL: SiteSettingsRegistry.defaultFile(for: profile)) }
    )

    private let makePersistence: (BrowserProfileID) -> any SitePermissionPersistence
    private let offTheRecord: OffTheRecordProfiles
    private var stores: [BrowserProfileID: SitePermissionStore] = [:]

    public init(persistence: @escaping (BrowserProfileID) -> any SitePermissionPersistence,
                offTheRecord: OffTheRecordProfiles = .shared) {
        makePersistence = persistence
        self.offTheRecord = offTheRecord
        offTheRecord.observeEnd { [weak self] profile in self?.stores[profile] = nil }
    }

    /// The store for `profile`, loading it on first use. An off-the-record
    /// profile (an incognito window) keeps its decisions in memory only.
    public func permissions(for profile: BrowserProfileID) -> SitePermissionStore {
        if let store = stores[profile] { return store }
        let persistence: any SitePermissionPersistence = offTheRecord.isOffTheRecord(profile)
            ? MemorySitePermissionPersistence() : makePersistence(profile)
        let store = SitePermissionStore(profile: profile, persistence: persistence)
        stores[profile] = store
        return store
    }

    /// `<Application Support>/<bundle id>/SiteSettings/<profile>.json`.
    /// Tagged DEV builds have their own bundle id, so data never mixes.
    public static func defaultFile(for profile: BrowserProfileID, bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let bundle = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "com.cmuxterm.app.next"
        return support.appending(path: bundle).appending(path: "SiteSettings")
            .appending(path: profile.rawValue.uuidString + ".json")
    }
}
