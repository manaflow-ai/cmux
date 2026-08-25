#if os(iOS)
import Foundation
import Observation

/// App-root What's New state: the binary catalog filtered by the
/// remote-authoritative visibility list, remote announcements targeted at
/// this app version, the cached copy of the last fetched list, and the
/// acknowledgement state.
///
/// Visibility policy (user-approved): the remote list is truth; the last
/// fetched list is cached on device and wins while offline; a device that
/// has NEVER fetched the list shows the binary entries (fail-open to binary
/// truth, because remote hiding is the exceptional operation).
///
/// Acknowledgement: binary pages advance a single "newest acknowledged entry
/// id" marker over the ordered catalog, so a user who skipped several
/// releases gets one sheet covering every unseen page. Announcements have no
/// stable order relative to the catalog (they arrive and expire remotely),
/// so they acknowledge into an id set.
@MainActor
@Observable
public final class MobileWhatsNewCenter {
    public typealias Loader = @Sendable (URL) async throws -> Data

    static let markerKey = "dev.cmux.mobile.whatsNew.newestAcknowledgedEntryId"
    static let acknowledgedAnnouncementsKey = "dev.cmux.mobile.whatsNew.acknowledgedAnnouncementIds"
    static let cacheKey = "dev.cmux.mobile.whatsNew.remoteList.v1"
    static let requestPath = "/api/whats-new"
    /// In-app What's New webpages may load cmux-owned hosts only.
    static let staticAllowedWebHosts: Set<String> = ["cmux.com", "www.cmux.com"]

    private let requestURL: URL?
    private let appVersion: String
    private let defaults: UserDefaults
    private let loader: Loader

    /// The last successfully fetched list (this launch or a previous one).
    /// `nil` means no list has EVER been fetched on this device.
    private(set) var remoteList: MobileWhatsNewRemoteList?
    /// True once a fetch succeeded this launch. Doubles as the online proxy
    /// that gates web-content pages into the one-time sheet, so an offline
    /// launch skips them instead of presenting an unloadable webview.
    private(set) var lastRefreshSucceeded = false

    public init(
        apiBaseURL: String?,
        appVersion: String? = nil,
        defaults: UserDefaults = .standard,
        loader: Loader? = nil
    ) {
        if let apiBaseURL, !apiBaseURL.isEmpty {
            requestURL = URL(string: apiBaseURL + Self.requestPath)
        } else {
            requestURL = nil
        }
        self.appVersion = appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0"
        self.defaults = defaults
        self.loader = loader ?? Self.urlSessionLoader
        if let cached = defaults.data(forKey: environmentCacheKey),
           let list = try? JSONDecoder().decode(MobileWhatsNewRemoteList.self, from: cached) {
            remoteList = list
        }
    }

    /// The cache key scoped to the configured API origin (scheme, host, and
    /// port), so a build that switches environments (production, staging,
    /// localhost dev servers on different ports) never consumes another
    /// environment's visibility list from the cache. A never-populated
    /// environment simply fails open to binary pages until its first fetch.
    private var environmentCacheKey: String {
        let scheme = requestURL?.scheme?.lowercased() ?? "none"
        let host = requestURL?.host?.lowercased() ?? "none"
        let port = requestURL?.port.map(String.init) ?? "default"
        return "\(Self.cacheKey).\(scheme).\(host).\(port)"
    }

    /// Fetches the remote list, replacing the device cache on success. Any
    /// failure (offline, server error, malformed payload) keeps the cached
    /// list: cache wins while offline.
    public func refresh() async {
        guard let requestURL else { return }
        do {
            let data = try await loader(requestURL)
            let list = try JSONDecoder().decode(MobileWhatsNewRemoteList.self, from: data)
            remoteList = list
            lastRefreshSucceeded = true
            defaults.set(data, forKey: environmentCacheKey)
            pruneAcknowledgedAnnouncements(against: list)
        } catch {
            // Keep the cached list; no cache ever fetched means binary
            // entries stay visible (fail-open to binary truth).
        }
    }

    /// Drops acknowledged announcement ids the authoritative list no longer
    /// carries. Announcements expire remotely and their ids never return, so
    /// without pruning the UserDefaults-backed set would grow without bound.
    private func pruneAcknowledgedAnnouncements(against list: MobileWhatsNewRemoteList) {
        let acknowledged = acknowledgedAnnouncementIDs
        guard !acknowledged.isEmpty else { return }
        let live = Set(list.announcements.map(\.id))
        let pruned = acknowledged.intersection(live)
        guard pruned != acknowledged else { return }
        defaults.set(pruned.sorted(), forKey: Self.acknowledgedAnnouncementsKey)
    }

    /// Hosts an in-app What's New webpage may load: the cmux-owned production
    /// hosts plus this build's configured API host (so dev and staging pages
    /// render against their own web app).
    var allowedWebHosts: Set<String> {
        var hosts = Self.staticAllowedWebHosts
        if let apiHost = requestURL?.host?.lowercased() {
            hosts.insert(apiHost)
        }
        return hosts
    }

    /// Binary catalog entries the remote list allows, in catalog order
    /// (newest first). Never-fetched devices show the full catalog.
    var visibleBinaryEntries: [MobileWhatsNewPage] {
        guard let remoteList else { return MobileWhatsNewCatalog.entries }
        let visible = Set(remoteList.visibleEntryIds)
        return MobileWhatsNewCatalog.entries.filter { visible.contains($0.id) }
    }

    /// Cached announcements targeted at this app version, resolved to
    /// renderable pages, in server order (newest first). An announcement
    /// whose referenced native entry is already visible as a binary page is
    /// dropped: that content is already delivered natively.
    var announcementPages: [MobileWhatsNewPage] {
        guard let remoteList else { return [] }
        let visibleBinaryIDs = Set(visibleBinaryEntries.map(\.id))
        return remoteList.announcements.compactMap { announcement in
            guard MobileAppVersionCompare.version(
                appVersion,
                isWithinMin: announcement.minVersion,
                max: announcement.maxVersion
            ) else { return nil }
            if let nativeID = announcement.nativeEntryId, visibleBinaryIDs.contains(nativeID) {
                return nil
            }
            return page(for: announcement)
        }
    }

    /// Everything Settings > What's New lists: announcements first (they are
    /// operationally newest), then the visible binary entries, newest first.
    var archivePages: [MobileWhatsNewPage] {
        announcementPages + visibleBinaryEntries
    }

    /// Pages the one-time launch sheet should show, newest first:
    /// unacknowledged announcements, then visible binary entries newer than
    /// the acknowledgement marker. Web-content pages are skipped while
    /// offline (they reappear once a fetch succeeds; the marker never
    /// advances past a page that was skipped this way unless a newer binary
    /// page was acknowledged above it).
    var unseenPages: [MobileWhatsNewPage] {
        let acknowledged = acknowledgedAnnouncementIDs
        let unseenAnnouncements = announcementPages.filter { !acknowledged.contains($0.id) }
        let visible = visibleBinaryEntries
        let unseenBinary: [MobileWhatsNewPage]
        if let marker = defaults.string(forKey: Self.markerKey) {
            if let markerIndex = MobileWhatsNewCatalog.index(ofID: marker) {
                unseenBinary = visible.filter { page in
                    (MobileWhatsNewCatalog.index(ofID: page.id) ?? Int.max) < markerIndex
                }
            } else {
                // The marker id is unknown to this binary (downgrade or a
                // rewritten catalog): stay quiet rather than replaying pages
                // the user already acknowledged.
                unseenBinary = []
            }
        } else {
            unseenBinary = visible
        }
        return (unseenAnnouncements + unseenBinary).filter { page in
            if case .web = page.body { return lastRefreshSucceeded }
            return true
        }
    }

    /// Records the given pages as seen: shown announcements join the
    /// acknowledged id set, and the marker advances (never retreats) to the
    /// newest shown binary entry.
    func acknowledge(_ pages: [MobileWhatsNewPage]) {
        var acknowledged = acknowledgedAnnouncementIDs
        for page in pages where page.isAnnouncement {
            acknowledged.insert(page.id)
        }
        defaults.set(acknowledged.sorted(), forKey: Self.acknowledgedAnnouncementsKey)

        let shownIndices = pages.compactMap { page in
            page.isAnnouncement ? nil : MobileWhatsNewCatalog.index(ofID: page.id)
        }
        guard let newestShown = shownIndices.min() else { return }
        let currentIndex = defaults.string(forKey: Self.markerKey)
            .flatMap(MobileWhatsNewCatalog.index(ofID:))
        if let currentIndex, currentIndex <= newestShown { return }
        defaults.set(MobileWhatsNewCatalog.entries[newestShown].id, forKey: Self.markerKey)
    }

    private var acknowledgedAnnouncementIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.acknowledgedAnnouncementsKey) ?? [])
    }

    /// Resolves an announcement to renderable content. A referenced native
    /// body never renders through an announcement: when the referenced entry
    /// is remotely visible the announcement is dropped upstream as a
    /// duplicate, and when it is hidden the operator retracted that content,
    /// so resurfacing it here would bypass the remote hide switch. Only the
    /// announcement's own fallback content (webpage, then inline feature
    /// rows) renders.
    private func page(for announcement: MobileWhatsNewRemoteAnnouncement) -> MobileWhatsNewPage? {
        guard let title = announcement.title, !title.isEmpty else { return nil }
        if let web = allowlistedWebURL(announcement.webUrl) {
            return MobileWhatsNewPage(
                id: announcement.id,
                releaseLabel: announcement.releaseLabel,
                title: title,
                body: .web(web),
                isAnnouncement: true
            )
        }
        if let features = announcement.features, !features.isEmpty {
            return MobileWhatsNewPage(
                id: announcement.id,
                releaseLabel: announcement.releaseLabel,
                title: title,
                body: .features(features.map { feature in
                    MobileWhatsNewFeature(
                        symbol: feature.symbol ?? "megaphone",
                        title: feature.title,
                        detail: feature.detail
                    )
                }),
                isAnnouncement: true
            )
        }
        return nil
    }

    /// A webpage URL is renderable only under the shared What's New web
    /// policy (`whatsNewWebURLAllowed`): https on an allowlisted cmux-owned
    /// host, or http solely for a loopback development host. The webview
    /// applies the same policy to every subsequent navigation.
    private func allowlistedWebURL(_ string: String?) -> URL? {
        guard let string,
              let url = URL(string: string),
              whatsNewWebURLAllowed(url, allowedHosts: allowedWebHosts) else { return nil }
        return url
    }

    private static let urlSessionLoader: Loader = { url in
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadRevalidatingCacheData,
            timeoutInterval: 10
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
#endif
