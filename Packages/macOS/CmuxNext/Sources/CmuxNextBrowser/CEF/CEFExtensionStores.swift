import struct CmuxSafeConcurrency.OwnerReference
import Foundation

/// The extension mirrors, one per profile, created on first use. Owns the
/// mirrors and decides which ones a Chromium extension change refreshes.
@MainActor
final class CEFExtensionStores {
    /// The runtime, which owns these as `CEFRuntime.extensionStores`.
    private let runtimeReference: OwnerReference<CEFRuntime>
    /// The runtime; nil (reported) only once it is gone.
    private var runtime: CEFRuntime? { runtimeReference.resolve() }
    private var stores: [BrowserProfileID: BrowserExtensionStore] = [:]
    /// The backend of a new mirror; nil: Chromium's (tests pass their own).
    private let makeBackend: ((BrowserProfileID) -> any BrowserExtensionBackend)?
    /// Page menu sources by extension id, version and folder: each manifest
    /// is read once per installed version (``withRowIcons(_:profile:)``).
    private var menuSources: [String: BrowserExtensionMenuSource] = [:]

    init(runtime: CEFRuntime, makeBackend: ((BrowserProfileID) -> any BrowserExtensionBackend)? = nil) {
        runtimeReference = CEFRuntime.childReference(runtime)
        self.makeBackend = makeBackend
    }

    /// The extension mirror of `profile` (created on first use, empty).
    func store(for profile: BrowserProfileID) -> BrowserExtensionStore {
        if let store = stores[profile] { return store }
        let backend = makeBackend?(profile) ?? CEFExtensionBackend(runtime: runtimeReference, profile: profile)
        let store = BrowserExtensionStore(profile: profile, backend: backend)
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
        guard let runtime else { return }
        runtime.omniboxKeywords.invalidate()
        var profiles: Set<BrowserProfileID> = []
        if let tab = runtime.tabsByBrowser[browser] { profiles.insert(tab.profileID) }
        for host in runtime.hosts.values where host.owns(window: window) { profiles.insert(host.key.profile) }
        guard !profiles.isEmpty else { return refreshAll() }
        for profile in profiles { stores[profile]?.refresh() }
    }
}
