public import Foundation

/// cmux-page:// first-party pages for Chromium tabs. The app sets the checked
/// table (CmuxNextApp `FirstPartyPageSchemes`) before Chromium starts;
/// `CEFRuntime` hands each entry to `cmux_shim_page_scheme_add_first_party`
/// when it initializes CEF. The shim refuses a reserved (`cmux.`) id on any
/// other path.
@MainActor
public struct CEFPageSchemes {
    public init() {}
    /// A first-party page: its bundled resource root and its own
    /// Content-Security-Policy (the page's `PageCSP` header; the shim's
    /// default `default-src 'self'` would block its inline module scripts).
    public struct Entry: Equatable, Sendable {
        public var root: URL
        public var csp: String
        /// First path components the page host answers (the page's dynamic prefixes, `__patch`):
        /// Chromium asks the tab's ``CEFTab/pageResources`` for every request under one and never
        /// serves a file there.
        public var dynamicPrefixes: [String]
        /// The file `cmux-page://<id>/` serves (`index.html`, or a shared build's own page,
        /// `diff-page.html`).
        public var entry: String
        /// The renderer group the fork puts the page in, shared with every page of the same key (a
        /// sharing `PageProcessGroup` raw value: `agent`, `privileged`, `viewer`). Nil: the page is in
        /// no group and keeps Chromium's default of one process per origin, as every `solo` and
        /// `secrets` page does.
        public var processGroup: String?
        /// The most main frames one renderer this page shares takes (PL-memory's
        /// `cmux-page-scheme-process-per-site` entry for its host, ``siteCaps(_:)``). Nil: the page has no
        /// entry and never joins a live renderer, as every `solo` and `secrets` page.
        public var mainFrameCap: Int?
        public init(root: URL, csp: String, dynamicPrefixes: [String] = [], entry: String = "index.html",
                    processGroup: String? = nil, mainFrameCap: Int? = nil) {
            self.root = root
            self.csp = csp
            self.dynamicPrefixes = dynamicPrefixes
            self.entry = entry
            self.processGroup = processGroup
            self.mainFrameCap = mainFrameCap
        }
    }

    /// The main-frame cap of a shared cmux page renderer. Chrome gives every NTP one renderer with no
    /// cap (ChromeContentBrowserClient::ShouldUseProcessPerSite); 8 bounds how many pages one renderer
    /// crash or one streaming chat reaches (plans/cmux-next/chrome-parity/p13-webui.md, risk 4).
    public nonisolated static let sharedRendererMainFrames = 8

    /// PL-memory's sharing table for `entries`, sorted by site so the switch is the same on every
    /// launch: one entry per page host that has a cap (`cmux.agent:8`), and one per process group of
    /// those pages (`privileged:8`). The fork uses a host's own entry first, then its registered
    /// group's (webui-DESIGN.md 3.2), so a host entry shares only between pages of one host and a
    /// group entry shares across the group's hosts.
    static func siteCaps(_ entries: [String: Entry]) -> [CEFSwitches.PageSiteCap] {
        var caps: [String: Int] = [:]
        for (id, entry) in entries {
            guard let cap = entry.mainFrameCap else { continue }
            caps[id] = cap
            if let group = entry.processGroup { caps[group] = min(caps[group] ?? cap, cap) }
        }
        return caps.map { CEFSwitches.PageSiteCap(site: $0.key, mainFrames: $0.value) }.sorted { $0.site < $1.site }
    }

    /// Page id (`cmux.agent`) to its entry.
    public static var firstParty: [String: Entry] = [:]

    /// Adds each entry to `shim` (`cmux_shim_page_scheme_add_first_party`, or its dynamic form for a page
    /// with dynamic prefixes or its own entry file), then each entry's process group when the shim exports
    /// `cmux_shim_page_scheme_set_group` (``CEFShimLibrary/pageSchemeSetGroup``). Call before `CefInitialize`.
    ///
    /// - Returns: The page ids the shim refused, and the ids whose group it refused, each sorted.
    static func add(_ entries: [String: Entry], to shim: CEFShimLibrary) -> (pages: [String], groups: [String]) {
        let pages = entries.compactMap { id, entry -> String? in
            let added = entry.dynamicPrefixes.isEmpty && entry.entry == "index.html"
                ? shim.pageSchemeAddFirstParty(id, entry.root.path, entry.csp)
                : shim.pageSchemeAddFirstPartyDynamic(id, entry.root.path, entry.csp, entry.dynamicPrefixes.joined(separator: "\n"),
                                                      entry.entry)
            return added == 1 ? nil : id
        }.sorted()
        guard let setGroup = shim.pageSchemeSetGroup else { return (pages, []) }
        return (pages, registerProcessGroups(entries) { id, group in setGroup(id, group) == 1 })
    }

    /// Hands each grouped entry's process group to the fork through `setGroup` (the shim's
    /// `cmux_shim_page_scheme_set_group`; true when the fork took it) before `CefInitialize` returns,
    /// so Chromium knows a page's group when it computes the page's process lock. An entry with no
    /// group makes no call, so a table made with the feature off makes none.
    ///
    /// - Returns: The ids the fork refused, sorted.
    static func registerProcessGroups(_ entries: [String: Entry], setGroup: (_ id: String, _ group: String) -> Bool) -> [String] {
        entries.compactMap { id, entry in
            guard let group = entry.processGroup else { return nil }
            return setGroup(id, group) ? nil : id
        }.sorted()
    }
}
