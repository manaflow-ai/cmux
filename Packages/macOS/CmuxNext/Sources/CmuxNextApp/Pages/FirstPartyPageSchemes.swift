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
        return roots.filter { id, _ in descriptors.contains { $0.id == id } }
    }

    /// Why `id` may not be served from `root`, nil when it may.
    static func refusal(id: String, root: URL, bundleResources: URL) -> Refusal? {
        guard PageID.isReserved(id) else { return .notReserved(id) }
        guard descriptors.contains(where: { $0.id == id.lowercased() }) else { return .notShipped(id) }
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
    static func entries(roots: [String: URL], bundleResources: URL) -> [String: CEFPageSchemes.Entry] {
        var out: [String: CEFPageSchemes.Entry] = [:]
        for (id, root) in accepted(roots: roots, bundleResources: bundleResources) {
            guard let page = descriptors.first(where: { $0.id == id }) else { continue }
            out[id] = CEFPageSchemes.Entry(root: root, csp: page.csp.header, dynamicPrefixes: page.dynamicPrefixes.sorted(),
                                           entry: page.entry)
        }
        return out
    }

    /// Hands the checked table to Chromium; call before Chromium starts.
    @MainActor static func install(bundle: Bundle = .main) {
        guard let resources = bundle.resourceURL else { return }
        CEFPageSchemes.firstParty = entries(roots: bundledRoots(), bundleResources: resources)
    }

    /// Real paths, compared component by component (`Resources2` is not inside `Resources`).
    static func isStrictlyInside(_ url: URL, _ folder: URL) -> Bool {
        let inner = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let outer = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return inner.count > outer.count && Array(inner.prefix(outer.count)) == outer
    }
}
