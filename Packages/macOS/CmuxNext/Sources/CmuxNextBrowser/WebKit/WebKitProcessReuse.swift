public import CmuxNextWakeups
public import Foundation
public import WebKit

/// Chrome's same-site renderer reuse above its process limit, for WebKit browser tabs (the
/// `webKitSameSiteProcesses` feature, plans/cmux-next/chrome-parity/p07-memory.md section E).
///
/// WebKit starts a WebContent process for every web view. Chrome stops doing that at its soft
/// limit (content/browser/renderer_host/render_process_host_impl.cc, `GetMaxRendererProcessCount`
/// and `IsProcessLimitReached`): from there a new main frame takes an existing process of its own
/// site (`GetExistingProcessHost`, `IsSuitableHost`), and never one that holds another site. Here,
/// once the live WebKit tab processes reach ``rendererLimit`` (`SubsystemBudget.chromiumRendererLimit`,
/// the Chromium engine's limit), a new tab whose first URL is of the same site as every tab of a
/// live process is made with that process's tab as its related web view (`_relatedWebView`, the
/// SPI ``WebProcessGroups`` uses), so it runs there. Below the limit, for a site no process holds
/// alone, for a page-opened tab, and on a WebKit without the SPI, a tab starts its own process.
///
/// A site is Chrome's: the scheme and the registrable domain (eTLD+1) from the Public Suffix List
/// (``PublicSuffixList``, private section included, so `a.github.io` and `b.github.io` are two
/// sites). It fails closed: until the list is read (``publicSuffixes``), and for an IP address, a
/// public suffix or a scheme other than http and https, a tab has no site and shares nothing.
///
/// ```swift
/// let reuse = WebKitProcessReuse.loading(rendererLimit: budget.chromiumRendererLimit, work: work, mainWork: mainWork)
/// let engine = WebKitEngine(fileInput: panel, stores: stores, processReuse: reuse, deadlines: deadlines, appEvents: events)
/// ```
@MainActor
public final class WebKitProcessReuse {
    /// Chrome's site of a page: scheme plus registrable domain (content/browser/site_info.cc, `GetSiteForURL`).
    public nonisolated struct Site: Hashable, Sendable {
        public let scheme: String
        public let domain: String
    }

    /// The live WebKit tab processes at which a new same-site tab joins one (at least 1).
    public let rendererLimit: Int
    /// The list that decides sites; nil until it is read, and no tab shares meanwhile.
    public var publicSuffixes: PublicSuffixList?
    /// A tab's WebContent process id, nil before it runs (`_webProcessIdentifier`; tests replace it).
    var processIdentifier: @MainActor (WebKitTab) -> Int32? = { tab in
        if case .pids(let pids) = tab.contentProcesses { pids.first } else { nil }
    }

    /// - Parameters:
    ///   - rendererLimit: The process count at which tabs start to share (`SubsystemBudget.chromiumRendererLimit`).
    ///   - publicSuffixes: The list that decides sites; nil until it is read (``loading(rendererLimit:work:mainWork:)``).
    public init(rendererLimit: Int, publicSuffixes: PublicSuffixList? = nil) {
        self.rendererLimit = max(rendererLimit, 1)
        self.publicSuffixes = publicSuffixes
    }

    /// The app's reuse: the bundled list is read on `work`'s files lane at best effort and lands on `mainWork`;
    /// tabs made before it lands start their own processes, and new tabs join them once it has landed.
    public static func loading(rendererLimit: Int, work: BackgroundWork, mainWork: MainWorkScheduler) -> WebKitProcessReuse {
        let reuse = WebKitProcessReuse(rendererLimit: rendererLimit)
        work.run(.bestEffort, mayBlock: .files) { PublicSuffixList.bundled() }
            .reply(on: mainWork, class: .background, owner: "WebKitProcessReuse.suffixes") { [weak reuse] list in
                reuse?.publicSuffixes = list
            }
        return reuse
    }

    /// The renderer limit a bench run forces (`CMUX_NEXT_BENCH_WEBKIT_RENDERER_LIMIT`, a positive integer), read by
    /// Debug and bench builds of development bundles only, as `CMUX_NEXT_BENCH_CEF_SWITCHES` is (``CEFSwitches``).
    public static func benchRendererLimit(environment: [String: String], bundleIdentifier: String?) -> Int? {
        #if DEBUG || CMUX_BENCH_HOOKS
        let bundle = bundleIdentifier ?? ""
        guard bundle.contains(".debug") || bundle.hasSuffix(".dev"),
              let value = environment["CMUX_NEXT_BENCH_WEBKIT_RENDERER_LIMIT"].flatMap(Int.init), value > 0 else { return nil }
        return value
        #else
        return nil
        #endif
    }

    /// The site of `url`, nil when it has none (see the type's notes).
    public func site(of url: URL?) -> Site? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: true),
              let domain = publicSuffixes?.registrableDomain(of: host) else { return nil }
        return Site(scheme: scheme, domain: domain)
    }

    /// The open tab whose process a new tab of `profile` with first-URL site `site` joins, or nil for a process of
    /// its own. Sets that tab's web view as `configuration`'s related web view (and its process pool, which WebKit
    /// requires to match). Below ``rendererLimit`` live processes, nil.
    func join(_ configuration: WKWebViewConfiguration, site: Site?, profile: BrowserProfileID,
              among tabs: [WebKitTab]) -> WebKitTab? {
        guard let site else { return nil }
        var processes: [ProcessKey: [WebKitTab]] = [:]
        for tab in tabs where !tab.isClosed {
            if let key = processKey(of: tab) { processes[key, default: []].append(tab) }
        }
        guard processes.count >= rendererLimit else { return nil }
        // IsSuitableHost: a process locked to this site, of this profile and its store (incognito never mixes).
        let store = configuration.websiteDataStore
        let suitable = processes.values.filter { members in
            members.allSatisfy { self.site(of: $0) == site && $0.profileID == profile
                && $0.webView.configuration.websiteDataStore === store }
        }
        // The process with the fewest tabs, so load spreads as Chrome's random pick spreads it.
        guard let members = suitable.min(by: { $0.count < $1.count }),
              let anchor = members.first(where: { $0.processAnchor == nil }) ?? members.first,
              Self.relate(configuration, to: anchor.webView) else { return nil }
        return anchor
    }

    /// The site `tab`'s process holds: its committed (or first) document's, or, for a tab whose site was decided
    /// before ``publicSuffixes`` landed, its page's now.
    private func site(of tab: WebKitTab) -> Site? {
        tab.processSite ?? site(of: tab.webView.url)
    }

    /// The process `tab` runs in: its WebContent pid, else (before it runs) its anchor's, else the anchor itself
    /// while it has a page to load. Nil for a tab that never loaded anything or whose process ended (a crash or a
    /// jetsam kill: no process until its next load).
    private func processKey(of tab: WebKitTab) -> ProcessKey? {
        if let pid = processIdentifier(tab), pid > 0 { return .pid(pid) }
        guard tab.state.processExit == nil else { return nil }
        let root = tab.processAnchor ?? tab
        if root !== tab, let pid = processIdentifier(root), pid > 0 { return .pid(pid) }
        guard tab.processSite != nil || tab.webView.url != nil else { return nil }
        return .pending(ObjectIdentifier(root))
    }

    private enum ProcessKey: Hashable {
        case pid(Int32)
        case pending(ObjectIdentifier)
    }

    /// Sets `_relatedWebView`; false when this WebKit has no such SPI (the tab gets its own process).
    private static func relate(_ configuration: WKWebViewConfiguration, to view: WKWebView) -> Bool {
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        let selector = NSSelectorFromString("_setRelatedWebView:")
        guard configuration.responds(to: selector) else { return false }
        // WebKit raises when a related view's pool differs from the configuration's.
        configuration.processPool = view.configuration.processPool
        // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists (no unknown-selector exception).
        configuration.perform(selector, with: view)
        return true
    }
}
