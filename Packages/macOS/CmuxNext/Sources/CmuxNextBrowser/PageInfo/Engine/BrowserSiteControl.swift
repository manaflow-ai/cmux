public import Foundation

/// Per-site control of the App's open pages for extensions (`browser.site.*`, `apps-site-styles`):
/// Page Info's JavaScript row (the profile's ``SitePermissionStore``, Chromium's content setting,
/// a reload of the origin's open tabs) and the daemon's style installers, which it runs on open pages
/// when a snapshot arrives, and on each later document: from its start in Chromium
/// (``BrowserSharedStores/documentStartScript``), at its commit in WebKit and on Chromium's renderer
/// paths (``BrowserSharedStores/documentCommitScripts``).
/// The App hands it its live pages and the selected tab.
@MainActor
public final class BrowserSiteControl {
    private let stores: BrowserSharedStores
    private let settings: SiteSettingsRegistry
    private let pages: () -> [String: any BrowserTab]
    private let selected: () -> String?
    /// Each origin's installers from the latest snapshot (memory only; the daemon persists them).
    private var kept: [String: [String]] = [:]

    /// - Parameters:
    ///   - stores: The App's stores: their site settings, and their commit scripts become this control's.
    ///   - pages: The live pages by tab id.
    ///   - selected: The tab id the key window's focused pane shows.
    public init(stores: BrowserSharedStores, pages: @escaping () -> [String: any BrowserTab], selected: @escaping () -> String?) {
        self.stores = stores
        settings = stores.siteSettings
        self.pages = pages
        self.selected = selected
        stores.documentCommitScripts = { [weak self] origin in self?.kept[origin] ?? [] }
    }

    /// A new style snapshot: `now` runs on the open pages of each origin, `kept` on later documents:
    /// from their start in Chromium (``BrowserSharedStores/documentStartScript``), at commit in WebKit.
    public func applyStyles(_ styles: (now: [String: [String]], kept: [String: [String]])) {
        kept = styles.kept
        let start = Self.documentStartScript(styles.kept)
        if start != stores.documentStartScript {
            stores.documentStartScript = start
            CEFRuntime.shared.syncSiteStyles()
        }
        runInstallers(styles.now)
    }

    /// Every origin's installers as one script for the start of each document: a top-level document
    /// runs its own origin's, in order, and any other runs none. Origins in sorted order, so the same
    /// snapshot gives the same script. "" for no installers. Each origin's installers sit in a
    /// function the script calls only for that origin, so a document parses the others lazily.
    public nonisolated static func documentStartScript(_ byOrigin: [String: [String]]) -> String {
        let entries = byOrigin.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.compactMap { origin, scripts -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: [origin], options: [.withoutEscapingSlashes]),
                  let list = String(data: data, encoding: .utf8) else { return nil }
            let key = String(list.dropFirst().dropLast())
            return "\(key):function(){\n\(scripts.joined(separator: "\n;\n"))\n;}"
        }
        guard !entries.isEmpty else { return "" }
        return "(()=>{if(window!==window.top)return;const run={\(entries.joined(separator: ",\n"))};"
            + "const f=Object.prototype.hasOwnProperty.call(run,location.origin)?run[location.origin]:null;if(f)f()})()"
    }

    /// The page of tab `id`, or with nil of the selected tab; nil when it is no live browser page.
    private func page(_ id: String?) -> (any BrowserTab)? {
        (id ?? selected()).flatMap { pages()[$0] }
    }

    /// The document origin of tab `id` (nil: the selected tab): nil without such a page, `.some(nil)`
    /// for a page with no origin.
    public func tabOrigin(_ id: String?) -> String?? {
        page(id).map { $0.state.url.flatMap(PageInfoSite.origin(of:)) }
    }

    private func profile(_ tab: String?) -> BrowserProfileID { page(tab)?.profileID ?? .default }

    /// Whether `origin` may run JavaScript in the profile of `tab` (the default profile without one).
    public func javaScriptAllowed(_ origin: String, tab: String?) -> Bool {
        settings.permissions(for: profile(tab)).setting(.javascript, for: origin) != .block
    }

    /// Page Info's JavaScript row: the profile's store, Chromium's content setting, then a reload of
    /// the origin's open tabs (WebKit decides JavaScript per navigation from the store).
    public func setJavaScript(_ allowed: Bool, origin: String, tab: String?) async {
        let profile = profile(tab)
        let store = settings.permissions(for: profile)
        await store.whenLoaded()
        let setting: SitePermissionSetting = allowed ? .allow : .block
        store.set(setting, .javascript, for: origin)
        // Chromium's content setting, on every context of the profile, whether or not one of its
        // pages is open; a context made later gets the store's decisions before its first page.
        CEFRuntime.shared.pushSiteDecision(.javascript, setting, origin: origin, profile: profile)
        for page in pages().values where page.profileID == profile && page.state.url.flatMap(PageInfoSite.origin(of:)) == origin {
            if let provider = page as? any PageInfoProviding {
                provider.pageInfoActivity.recordChange(.javascript)
                await provider.pageInfoDidChange(.javascript, to: setting, origin: origin)
            }
            page.reload()
        }
    }

    /// Runs each origin's installers, in order, in the isolated world of every open page of that origin.
    public func runInstallers(_ byOrigin: [String: [String]]) {
        guard !byOrigin.isEmpty else { return }
        for page in pages().values {
            guard let origin = page.state.url.flatMap(PageInfoSite.origin(of:)), let scripts = byOrigin[origin] else { continue }
            // task-owner: one page's installers for this snapshot, in order; a closed page drops them
            Task { [weak page] in
                for script in scripts { _ = try? await page?.evaluate(script, world: .isolated, gesture: .cmux) }
            }
        }
    }

    /// `raw` as Page Info's origin key when it is an http(s) `scheme://host[:port]` (no path, query or fragment).
    public nonisolated static func webOrigin(_ raw: String) -> String? {
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.path().isEmpty || url.path() == "/", url.query() == nil, url.fragment() == nil, url.user() == nil else { return nil }
        return PageInfoSite.origin(of: url)
    }
}
