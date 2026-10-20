import Foundation

/// The extension mirrors, one per profile, created on first use. Owns the
/// mirrors and decides which ones a Chromium extension change refreshes.
@MainActor
final class CEFExtensionStores {
    unowned let runtime: CEFRuntime
    private var stores: [BrowserProfileID: BrowserExtensionStore] = [:]
    /// Page menu sources by extension id, version and folder: each manifest
    /// is read once per installed version (``withRowIcons(_:profile:)``).
    private var menuSources: [String: BrowserExtensionMenuSource] = [:]

    init(runtime: CEFRuntime) {
        self.runtime = runtime
    }

    /// The extension mirror of `profile` (created on first use).
    func store(for profile: BrowserProfileID) -> BrowserExtensionStore {
        if let store = stores[profile] { return store }
        let store = BrowserExtensionStore(profile: profile, backend: CEFExtensionBackend(runtime: runtime, profile: profile))
        stores[profile] = store
        return store
    }

    func hasStore(for profile: BrowserProfileID) -> Bool { stores[profile] != nil }

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
        if profiles.isEmpty { profiles = Set(stores.keys) }
        for profile in profiles { stores[profile]?.refresh() }
    }
}
