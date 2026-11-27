import Foundation

/// The extension mirrors, one per profile, created on first use. Owns the
/// mirrors and decides which ones a Chromium extension change refreshes.
@MainActor
final class CEFExtensionStores {
    unowned let runtime: CEFRuntime
    private var stores: [BrowserProfileID: BrowserExtensionStore] = [:]
    /// The backend of a new mirror; nil: Chromium's (tests pass their own).
    private let makeBackend: ((BrowserProfileID) -> any BrowserExtensionBackend)?
    /// Page menu sources by extension id, version and folder: each manifest
    /// is read once per installed version (``withRowIcons(_:profile:)``).
    private var menuSources: [String: BrowserExtensionMenuSource] = [:]
    /// Manifest facts by extension folder (one installed version), nil for a folder with no
    /// readable manifest: read once, by ``scriptsPage(at:profile:)``.
    private var siteFacts: [String: ExtensionManifestFacts?] = [:]
    /// ``scriptsPage(at:profile:)`` answers by profile and site (scheme and host), for the mirror
    /// revision they were made from: the freeze planner asks for each hidden page on each tab switch.
    private var siteAnswers: [BrowserProfileID: (revision: Int, sites: [String: Bool])] = [:]
    /// Unpacked folders an import copied, by profile, waiting for a Chromium page of that profile:
    /// the fork loads an extension through one of the profile's browsers (``loadUnpacked(_:into:)``).
    private var pendingUnpacked: [BrowserProfileID: [String]] = [:]

    init(runtime: CEFRuntime, makeBackend: ((BrowserProfileID) -> any BrowserExtensionBackend)? = nil) {
        self.runtime = runtime
        self.makeBackend = makeBackend
    }

    /// The extension mirror of `profile` (created on first use, empty).
    func store(for profile: BrowserProfileID) -> BrowserExtensionStore {
        if let store = stores[profile] { return store }
        let store = BrowserExtensionStore(profile: profile, backend: makeBackend?(profile) ?? CEFExtensionBackend(runtime: runtime, profile: profile))
        stores[profile] = store
        return store
    }

    /// The mirror of `profile` for a reader (the browser host, Settings, menus): filled from
    /// Chromium once, when it is made. A read never asks Chromium again: the fork's extension and
    /// action events (``refresh(window:browser:)``) and each new window (`CEFPaneHost.windowCreated`)
    /// keep it current. A refresh per read was a synchronous `cmux_ext_list` per Chromium tab on
    /// every tab-list change (PL-burst, STRESS: 99.6 ms on new tab, Cmd-W and move).
    func readyStore(for profile: BrowserProfileID) -> BrowserExtensionStore {
        let made = stores[profile] == nil
        let store = store(for: profile)
        if made { store.refresh() }
        return store
    }

    /// Refreshes every mirror (tests; an extension event of no known window).
    func refreshAll() {
        for store in stores.values { store.refresh() }
    }

    func hasStore(for profile: BrowserProfileID) -> Bool { stores[profile] != nil }

    /// Loads the unpacked extension `folders` into `profile`: now when a Chromium page of it is
    /// open, else when the first one registers (``browserRegistered(_:)``). Answers the folders
    /// loaded now; a refused one is logged by the caller's next list, not retried.
    @discardableResult
    func loadUnpacked(_ folders: [String], into profile: BrowserProfileID) -> [String] {
        guard !folders.isEmpty else { return [] }
        guard runtime.tabsByBrowser.values.contains(where: { $0.profileID == profile }) else {
            pendingUnpacked[profile, default: []].append(contentsOf: folders)
            return []
        }
        let store = store(for: profile)
        let loaded = folders.filter { store.loadUnpacked(at: $0) }
        store.refresh()
        return loaded
    }

    /// Whether an import's unpacked folders wait for a Chromium page of `profile`.
    func hasPendingUnpacked(_ profile: BrowserProfileID) -> Bool { pendingUnpacked[profile] != nil }

    /// A Chromium browser of `profile` registered: the import's unpacked folders waiting for one load.
    func browserRegistered(_ profile: BrowserProfileID) {
        guard let folders = pendingUnpacked.removeValue(forKey: profile) else { return }
        loadUnpacked(folders, into: profile)
    }

    /// A tab of `profile`'s page menu `items` with the icons Chrome draws and
    /// CEF's model drops: each extension row its extension's icon
    /// (``BrowserExtensionMenuIcons``, from the profile's mirror; a menu
    /// without extension rows costs nothing), Translate and Cast theirs.
    func withRowIcons(_ items: [BrowserContextMenuItem], profile: BrowserProfileID) -> [BrowserContextMenuItem] {
        guard BrowserExtensionMenuIcons.hasExtensionRows(items) else { return BrowserContextMenuItem.withChromeIcons(items) }
        let store = store(for: profile)
        if store.extensions.isEmpty { store.refresh() }
        let sources = store.extensions.filter { $0.isEnabled && !$0.isTerminated }.map(menuSource)
        return BrowserContextMenuItem.withChromeIcons(BrowserExtensionMenuIcons(sources: sources).annotate(items))
    }

    /// True when an enabled Manifest V3 extension of `profile` can run its scripts in the web page at
    /// `url`: its manifest asks for all sites or for this one (`ExtensionSiteAccess`). Only MV3 counts:
    /// its service worker stops when idle, and the disconnect of each port it held is lost on a frozen
    /// page; an MV2 background page (the built-in uBlock Origin) stays. An MV3 extension whose manifest
    /// was not read counts too: a page kept awake costs power, a frozen one breaks the extension.
    /// Reads each installed version's small manifest once, on the first ask. Not seen: site access
    /// given at run time (`optional_host_permissions`, an `activeTab` click), child frames, and an MV2
    /// extension's own `port.disconnect()` or reload while the page is frozen.
    func scriptsPage(at url: URL?, profile: BrowserProfileID) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let store = readyStore(for: profile)
        let site = scheme + "://" + (url.host()?.lowercased() ?? "")
        var answers = siteAnswers[profile].flatMap { $0.revision == store.revision ? $0.sites : nil } ?? [:]
        if let known = answers[site] { return known }
        let scripts = store.extensions.contains { info in
            guard info.isEnabled, !info.isTerminated, info.manifestVersion >= 3 else { return false }
            switch ExtensionSiteAccess(facts(of: info), url: url) {
            case .allSites, .thisSite, .unknown: return true
            case .whenClicked, .none: return false
            }
        }
        answers[site] = scripts
        siteAnswers[profile] = (store.revision, answers)
        return scripts
    }

    private func facts(of info: BrowserExtensionInfo) -> ExtensionManifestFacts? {
        guard !info.path.isEmpty else { return nil }
        if let cached = siteFacts[info.path] { return cached }
        let read = ExtensionManifestFacts(folder: info.path)
        siteFacts[info.path] = .some(read)
        return read
    }

    /// `info`'s menu source. Reads its small manifest on the main thread
    /// once per installed version, on the first right-click that needs it.
    private func menuSource(_ info: BrowserExtensionInfo) -> BrowserExtensionMenuSource {
        let key = "\(info.id)\u{1}\(info.version)\u{1}\(info.path)\u{1}\(info.name)"
        if let cached = menuSources[key] { return cached }
        var source = info.path.isEmpty
            ? BrowserExtensionMenuSource(id: info.id, name: info.name)
            : BrowserExtensionMenuSource(id: info.id, name: info.name, folder: URL(fileURLWithPath: info.path))
        // The fork's own pick (its largest icon) when the manifest gave none.
        if source.icon1x == nil, source.icon2x == nil, let icon = info.iconPath, !icon.isEmpty {
            source.icon1x = icon
            source.icon2x = icon
        }
        menuSources[key] = source
        return source
    }

    /// Extensions or their actions changed: refresh the profile mirrors of
    /// the window's tabs (a pin changes both lists).
    func refresh(window: Int32, browser: Int32) {
        runtime.omniboxKeywords.invalidate()
        var profiles: Set<BrowserProfileID> = []
        if let tab = runtime.tabsByBrowser[browser] { profiles.insert(tab.profileID) }
        for host in runtime.hosts.values where host.owns(window: window) { profiles.insert(host.key.profile) }
        guard !profiles.isEmpty else { return refreshAll() }
        for profile in profiles { stores[profile]?.refresh() }
    }
}
