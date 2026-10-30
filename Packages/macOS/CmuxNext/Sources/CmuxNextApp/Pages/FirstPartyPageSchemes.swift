import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextPages
import Foundation

/// The cmux-page:// pages the app ships, which Chromium serves. A reserved host
/// (`PageID.isReserved`) is served only for a page the app ships
/// (``descriptors``) and only from that page's bundled resource root inside
/// the app's resources; an app page never gets a reserved host (the shim also
/// refuses one on its app-page call). Serving a page here changes no trust:
/// its CSP is its descriptor's (strict for an id outside the first-party table,
/// `PageID.firstParty`), and only that table's pages reach the daemon.
///
/// The shared chunk origin (`PageID.sharedHost`, `cmux-page://cmux.shared`) is in the table too, from
/// the pages bundle's `_shared` folder; the shim gives it its own handler, which is not a page (only
/// `.js` and `.css`, only to a first-party page origin, never a navigation).
enum FirstPartyPageSchemes {
    enum Refusal: Error, Equatable {
        /// Not a reserved id: app pages do not use this path.
        case notReserved(String)
        /// Reserved, but the app ships no page with this id.
        case notShipped(String)
        /// The root is not strictly inside the app's resources.
        case outsideBundle(String)
    }

    /// The agent pane's bundled page folder (`agent-pane`).
    @MainActor static var agentPaneRoot: URL? { AgentPaneView.bundledPage?.deletingLastPathComponent() }

    /// The bundled root of each first-party page that ships one.
    ///
    /// - Parameter registered: The root another module registered for a page id (the viewer pages'
    ///   shared `webviews-app` folder in the app's resources, `PageID.bundledRoot(for:)`).
    @MainActor static func bundledRoots(registered: (String) -> URL? = PageID.bundledRoot(for:)) -> [String: URL] {
        var roots: [String: URL] = [:]
        roots[PageDescriptor.agent.id] = agentPaneRoot
        for page in descriptors where page != .agent { roots[page.id] = page.pagesBundleRoot ?? registered(page.id) }
        roots[PageID.sharedHost] = PageID.sharedBundleRoot
        return roots.filter { id, _ in isServed(id) }
    }

    /// Whether the app serves `id` in Chromium: a page it ships, or the shared chunk origin.
    static func isServed(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return lowered == PageID.sharedHost || descriptors.contains { $0.id == lowered }
    }

    /// Why `id` may not be served from `root`, nil when it may.
    static func refusal(id: String, root: URL, bundleResources: URL) -> Refusal? {
        guard PageID.isReserved(id) else { return .notReserved(id) }
        guard isServed(id) else { return .notShipped(id) }
        guard isStrictlyInside(root, bundleResources) else { return .outsideBundle(id) }
        return nil
    }

    /// The entries of `roots` that pass ``refusal(id:root:bundleResources:)``.
    static func accepted(roots: [String: URL], bundleResources: URL) -> [String: URL] {
        roots.filter { refusal(id: $0.key, root: $0.value, bundleResources: bundleResources) == nil }
    }

    /// Every page the app ships with a bundled root: the first-party table (`FirstPartyPages.ids`)
    /// and the app's other `cmux.` pages, so each can show in Chromium (`PageEnginePolicy` still
    /// keeps a page that cannot on WebKit, with its reason).
    static let descriptors: [PageDescriptor] = [
        .agent, .history, .cloud, .apps, .settings, .keybindings, .diff, .markdown, .iconPicker, .passwords, .editor,
        .chiefInspector, .debugSettings, .homeChannels,
        .changelog, .coderouter, .files, .stats, .chiefUsage, .mobilePairing, .agentActivity,
    ]

    /// The accepted entries of `roots`, each with its page's own CSP.
    ///
    /// - Parameter processGroups: Each entry of a page whose ``PageDescriptor/processGroup`` shares a
    ///   renderer (``PageProcessGroup/sharesRenderer``) names that group, which the fork shares renderers
    ///   by (the `pageProcessGroups` feature). A `solo` or `secrets` page names none and keeps Chromium's
    ///   one process per origin: its raw value is a class, not a group, and two pages with one key would
    ///   share. Off, no entry names one.
    /// - Parameter rendererSharing: Each entry of a page whose group shares a renderer gets the shared
    ///   renderer's main-frame cap (``CEFPageSchemes/sharedRendererMainFrames``), so Chromium sends the
    ///   page's instances (New Tab and every chat of the agent page) to one live renderer, as Chrome
    ///   does for every NTP (the `cmuxPageRendererSharing` feature, PL-memory's switch). Pages of other
    ///   hosts join it only through a registered group, which needs `<page>.<group>` hosts
    ///   (webui-DESIGN.md 3.2). A `solo` or `secrets` page gets none and never joins one. Off, no entry
    ///   has a cap.
    static func entries(roots: [String: URL], bundleResources: URL, processGroups: Bool = false,
                        rendererSharing: Bool = false) -> [String: CEFPageSchemes.Entry] {
        var out: [String: CEFPageSchemes.Entry] = [:]
        for (id, root) in accepted(roots: roots, bundleResources: bundleResources) {
            if id.lowercased() == PageID.sharedHost {
                out[id] = CEFPageSchemes.Entry(root: root, csp: PageID.sharedChunkPolicy)
                continue
            }
            guard let page = descriptors.first(where: { $0.id == id }) else { continue }
            let shares = page.processGroup.sharesRenderer
            out[id] = CEFPageSchemes.Entry(root: root, csp: page.csp.header, dynamicPrefixes: page.dynamicPrefixes.sorted(),
                                           entry: page.entry, processGroup: processGroups && shares ? page.processGroup.rawValue : nil,
                                           mainFrameCap: rendererSharing && shares ? CEFPageSchemes.sharedRendererMainFrames : nil)
        }
        return out
    }

    /// Hands the checked table to Chromium; call before Chromium starts.
    ///
    /// - Parameter processGroups: The `pageProcessGroups` feature (``entries(roots:bundleResources:processGroups:rendererSharing:)``).
    /// - Parameter rendererSharing: The `cmuxPageRendererSharing` feature (the same).
    @MainActor static func install(bundle: Bundle = .main, processGroups: Bool, rendererSharing: Bool) {
        guard let resources = bundle.resourceURL else { return }
        CEFPageSchemes.firstParty = entries(roots: bundledRoots(), bundleResources: resources, processGroups: processGroups,
                                            rendererSharing: rendererSharing)
    }

    /// The page host's scripts for every renderer (fork API 29), in a cmux page's own world at
    /// document start: the composition root hands them to its `CEFEngine` when the feature
    /// `chromiumPageRendererPaths` is on, and the runtime's page host relay sends their posts on the
    /// page channel. Every handler a page view adds is named here, so a page has it at document start
    /// (the agent page's message menu).
    @MainActor static var hostScripts: [CEFPageSchemes.HostScript] {
        let source = ChromiumPageHostBridge.rendererScript(handlers: PageWebView.chromiumFireAndForget + [AgentPaneView.contextMenuHandler],
                                                           documentScripts: PageChromiumDocumentScripts.everyPage,
                                                           channelEvent: CEFPageSchemes.hostEvent)
        return [CEFPageSchemes.HostScript(world: "", source: source, allFrames: false)]
    }

    /// Real paths, compared component by component (`Resources2` is not inside `Resources`).
    static func isStrictlyInside(_ url: URL, _ folder: URL) -> Bool {
        let inner = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let outer = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return inner.count > outer.count && Array(inner.prefix(outer.count)) == outer
    }
}
