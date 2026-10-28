public import Foundation

/// cmux-page:// first-party pages for Chromium tabs. The app sets the checked
/// table (CmuxNextApp `FirstPartyPageSchemes`) before Chromium starts;
/// `CEFRuntime` hands each entry to `cmux_shim_page_scheme_add_first_party`
/// when it initializes CEF, in process or as a preinit op to the Chromium Host.
/// The shim refuses a reserved (`cmux.`) id on any other
/// path.
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

    /// A first-party page, or its renderer group, that the shim did not register (``add(_:through:refused:)``).
    enum Refusal: Equatable, Sendable {
        /// The page's id: the shim refused its scheme (`cmux_shim_page_scheme_add_first_party`, or its
        /// dynamic form).
        case page(String)
        /// The page's id: the fork refused its renderer group (`cmux_shim_page_scheme_set_group`).
        case group(String)
    }

    /// Adds each entry to `runtime`'s shim (`cmux_shim_page_scheme_add_first_party`, or its dynamic form
    /// for a page with dynamic prefixes or its own entry file), then each entry's process group when the
    /// shim exports `cmux_shim_page_scheme_set_group` (``CEFShimLibrary/pageSchemeSetGroup``), in id order,
    /// so Chromium knows a page's group when it computes the page's process lock. Call before
    /// `CefInitialize`. Every call is a preinit op: the Chromium Host applies it before its own
    /// `CefInitialize`, and the remote shim's replay log hands it to every host that replaces it.
    ///
    /// Each call is in the token form (``CEFRuntime/sendAsync(_:)``), as a mojo method with a reply
    /// callback: `refused` gets a refusal in the call in process, and in the turn of the host's REPLY in
    /// host mode. A call the remote shim's own check refused sent nothing (`unsent`), as the in-process
    /// shim refuses it. A passed deadline or an exited host is no refusal: that host may have applied the
    /// call, and the next one applies it from the replay log.
    ///
    /// - Parameters:
    ///   - entries: Page id (`cmux.agent`) to its entry. An entry with no group makes no group call, so a
    ///     table made with the `pageProcessGroups` feature off makes none.
    ///   - runtime: The runtime whose shim takes the calls.
    ///   - refused: Gets each refused page and each refused group.
    static func add(_ entries: [String: Entry], through runtime: CEFRuntime, refused: @escaping (Refusal) -> Void) {
        let ordered = entries.sorted { $0.key < $1.key }
        for (id, entry) in ordered {
            let sent: CEFShimAnswer<Int32> = if entry.dynamicPrefixes.isEmpty && entry.entry == "index.html" {
                runtime.sendAsync { shim in shim.pageSchemeAddFirstParty(id, entry.root.path, entry.csp) }
            } else {
                runtime.sendAsync { shim in
                    shim.pageSchemeAddFirstPartyDynamic(id, entry.root.path, entry.csp,
                                                        entry.dynamicPrefixes.joined(separator: "\n"), entry.entry)
                }
            }
            runtime.whenSettled(sent, label: "cmux-page \(id)") { if Self.isRefusal($0) { refused(.page(id)) } }
        }
        guard let setGroup = runtime.shim?.pageSchemeSetGroup else { return }
        for (id, entry) in ordered {
            guard let group = entry.processGroup else { continue }
            let sent = runtime.sendAsync { _ in setGroup(id, group) }
            runtime.whenSettled(sent, label: "cmux-page group \(id)") { if Self.isRefusal($0) { refused(.group(id)) } }
        }
    }

    /// Whether a settled registration is a refusal: any answer but 1, or a call refused before the wire
    /// (`unsent`). A passed deadline, a malformed REPLY or an exited host says nothing of the call.
    nonisolated static func isRefusal(_ settled: Result<Int32, CEFHostReplyError>) -> Bool {
        switch settled {
        case .success(let added): added != 1
        case .failure(.unsent): true
        case .failure: false
        }
    }
}
