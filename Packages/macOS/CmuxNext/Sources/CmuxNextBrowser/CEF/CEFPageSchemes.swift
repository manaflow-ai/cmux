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
        /// The renderer group the fork puts the page in (a `PageProcessGroup` raw value: `agent`,
        /// `privileged`, `viewer`, `solo`, `secrets`). Nil: the page is in no group and keeps
        /// Chromium's default of one process per origin.
        public var processGroup: String?
        public init(root: URL, csp: String, dynamicPrefixes: [String] = [], entry: String = "index.html",
                    processGroup: String? = nil) {
            self.root = root
            self.csp = csp
            self.dynamicPrefixes = dynamicPrefixes
            self.entry = entry
            self.processGroup = processGroup
        }
    }

    /// Page id (`cmux.agent`) to its entry.
    public static var firstParty: [String: Entry] = [:]

    /// Adds each entry to `shim` (`cmux_shim_page_scheme_add_first_party`, or its dynamic form for a page
    /// with dynamic prefixes or its own entry file), then each entry's process group when the shim exports
    /// `cmux_shim_page_scheme_set_group` (``CEFForkFeatures/pageProcessGroups``). Call before `CefInitialize`.
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
