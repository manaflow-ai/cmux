import CmuxBrowser
import CmuxCEF
import Foundation
import os

/// The Chromium engine's per-profile data, managed with the profile's WebKit
/// data (``BrowserProfileRepository/addEngineStore(_:)``): clearing a profile
/// clears its Chromium cookies, cache and remembered permission answers;
/// deleting it removes its Chromium store (now when Chromium has not opened
/// it in this process, otherwise at the next launch); browser import writes
/// its cookies.
///
/// Registered at launch only when the Chromium runtime is bundled, so a build
/// or launch without it behaves exactly as before.
@MainActor
final class BrowserChromiumProfileEngineStore: BrowserProfileEngineStoreManaging {
    let engineName = "chromium"

    private let runtime: CEFRuntime
    private let storage: BrowserChromiumProfileStorage
    private let cleanup: BrowserChromiumProfileStorageCleanup
    let sitePermissions: BrowserSitePermissionStoreRegistry
    private let logger = Logger(subsystem: "com.cmuxterm.app", category: "browser.chromium.profiles")

    /// Cookie database files a profile keeps (older and current Chromium layouts).
    static let cookieFileNames = ["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]

    /// `UserDefaults` key: Chromium permission answers to reset once a page of
    /// their profile runs (cmux forgot them while Chromium had not opened it).
    static let pendingPermissionResetsKey = "browserProfiles.chromiumPendingPermissionResets.v1"

    private let defaults: UserDefaults

    init(runtime: CEFRuntime, defaults: UserDefaults = .standard) {
        self.runtime = runtime
        self.defaults = defaults
        storage = BrowserChromiumProfileStorage(root: runtime.storage.root)
        cleanup = BrowserChromiumProfileStorageCleanup(storage: storage, defaults: defaults)
        sitePermissions = BrowserSitePermissionStoreRegistry(storage: storage)
    }

    /// The registered store (its site-permission answers are what Chromium
    /// panels ask from); `nil` when Chromium is not bundled.
    private(set) static weak var current: BrowserChromiumProfileEngineStore?

    /// Registers the store when Chromium is bundled and arranges launch-time
    /// cleanup of deleted profiles before Chromium opens any profile.
    /// - Returns: The registered store, or `nil` when Chromium is not bundled.
    @discardableResult
    static func registerIfAvailable(
        runtime: CEFRuntime = .shared,
        profiles: BrowserProfileStore = .shared
    ) -> BrowserChromiumProfileEngineStore? {
        guard runtime.unavailableReason != .notBundled else { return nil }
        let store = BrowserChromiumProfileEngineStore(runtime: runtime)
        current = store
        profiles.addEngineStore(store)
        runtime.addEventObserver { [weak store] event in
            guard case let .loadStart(browser, _, _) = event else { return }
            store?.applyPendingPermissionResets(browser: browser)
        }
        let previous = runtime.beforeInitialize
        runtime.beforeInitialize = { [weak store] in
            previous?()
            store?.removeDeletedProfilesBeforeLaunch()
        }
        return store
    }

    func clearAllData(forProfileID profileID: UUID) async -> [String] {
        // Only what existed is reported: a profile Chromium never stored
        // anything for clears nothing, so the reply matches a build without
        // Chromium.
        var kinds: [String] = []
        let forgotten = sitePermissions.reset(profileID: profileID)
        resetChromiumPermissions(forgotten, profileID: profileID)
        if !forgotten.isEmpty { kinds.append("sitePermissions") }
        let directory = storage.cachePath(forProfileID: profileID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return kinds }
        if runtime.hasOpened(profile: profileID) {
            if await runtime.clearCache(ofOpenedProfile: profileID) { kinds.append("cache") }
            do {
                try await runtime.clearCookies(profile: profileID)
                kinds.append("cookies")
            } catch {
                logger.error("chromium cookie clear failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            // Chromium has not opened the profile: its files are closed and
            // can go directly, without starting Chromium.
            let storage = storage
            let cookieFileNames = Self.cookieFileNames
            await Task.detached(priority: .utility) {
                BrowserChromiumProfileStorageCleanup.removeCaches(ofProfileID: profileID, in: storage)
                let profileDirectory = storage.cachePath(forProfileID: profileID)
                for name in cookieFileNames {
                    try? FileManager.default.removeItem(at: profileDirectory.appendingPathComponent(name))
                }
            }.value
            kinds.append("cache")
            kinds.append("cookies")
        }
        return kinds
    }

    func profileWasDeleted(_ profileID: UUID) {
        sitePermissions.retire(profileID: profileID)
        var pending = pendingPermissionResets
        if pending.removeValue(forKey: profileID.uuidString) != nil { pendingPermissionResets = pending }
        cleanup.markDeleted(profileID)
        let runtime = runtime
        let directories = cleanup.takeRemovable { runtime.hasOpened(profile: $0) }
        guard !directories.isEmpty else { return }
        Task.detached(priority: .utility) {
            BrowserChromiumProfileStorageCleanup.removeDirectories(directories)
        }
    }

    func importCookies(_ cookies: [HTTPCookie], intoProfileID profileID: UUID) async -> Int {
        // Imports go into a running Chromium only: starting the engine just
        // for an import would load it for people who never use it.
        guard runtime.isRunning else { return 0 }
        let writes = cookies.compactMap(BrowserChromiumCookieWrite.init(cookie:))
        guard !writes.isEmpty, let json = try? BrowserChromiumCookieWrite.shimJSON(writes) else { return 0 }
        do {
            return try await runtime.importCookies(json: json, profile: profileID).written
        } catch {
            logger.error("chromium cookie import failed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    // MARK: Chromium's own saved permission answers

    /// Chromium saves every prompt answer in its content settings; when cmux
    /// forgets answers it resets Chromium's copies to "ask", now through a
    /// live page of the profile, or once one runs.
    private func resetChromiumPermissions(_ forgotten: [BrowserSitePermissionStore.Entry], profileID: UUID) {
        let pairs = forgotten.compactMap { entry -> [String]? in
            BrowserChromiumPermissionRequest.contentSettingType(forKindKey: entry.kind).map { [entry.origin, $0] }
        }
        guard !pairs.isEmpty else { return }
        if let browser = runtime.liveBrowser(ofProfile: profileID)?.browserID {
            apply(pairs, browser: browser)
            return
        }
        var pending = pendingPermissionResets
        let existing = pending[profileID.uuidString] ?? []
        pending[profileID.uuidString] = existing + pairs.filter { !existing.contains($0) }
        pendingPermissionResets = pending
    }

    private func applyPendingPermissionResets(browser: Int32) {
        var pending = pendingPermissionResets
        guard !pending.isEmpty, let page = runtime.browser(id: browser),
              let profileID = pending.keys.compactMap(UUID.init(uuidString:)).first(where: {
                  page.contextKey == runtime.storage.contextKey(for: $0, offTheRecord: false)
              }),
              let pairs = pending.removeValue(forKey: profileID.uuidString) else { return }
        apply(pairs, browser: browser)
        pendingPermissionResets = pending
    }

    private func apply(_ pairs: [[String]], browser: Int32) {
        for pair in pairs where pair.count == 2 {
            runtime.setContentSetting(
                browser: browser, origin: pair[0], type: pair[1],
                value: BrowserChromiumPermissionRequest.contentSettingDefault
            )
        }
    }

    private var pendingPermissionResets: [String: [[String]]] {
        get { defaults.dictionary(forKey: Self.pendingPermissionResetsKey) as? [String: [[String]]] ?? [:] }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Self.pendingPermissionResetsKey)
            } else {
                defaults.set(newValue, forKey: Self.pendingPermissionResetsKey)
            }
        }
    }

    /// Before `CefInitialize`: finish deletions a previous run left pending
    /// (nothing is open yet) and sweep half-deleted leftovers.
    /// Deleted profiles are never opened again, so the deletion itself runs
    /// off the main thread without racing Chromium.
    private func removeDeletedProfilesBeforeLaunch() {
        let directories = cleanup.takeRemovable { _ in false }
        let storage = storage
        Task.detached(priority: .utility) {
            BrowserChromiumProfileStorageCleanup.removeDirectories(directories)
            BrowserChromiumProfileStorageCleanup.removeLeftovers(in: storage)
        }
    }
}
