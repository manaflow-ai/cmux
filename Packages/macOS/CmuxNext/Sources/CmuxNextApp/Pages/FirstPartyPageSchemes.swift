import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextPages
import Foundation

/// The first-party cmux-page:// pages Chromium tabs may load. A reserved host
/// (`PageID.isReserved`) is served only for an id of the first-party table
/// (`PageID.firstParty`) and only from that page's bundled resource root
/// inside the app's resources; an app page never gets a reserved host (the
/// shim also refuses one on its app-page call).
enum FirstPartyPageSchemes {
    enum Refusal: Error, Equatable {
        /// Not a reserved id: app pages do not use this path.
        case notReserved(String)
        /// Reserved, but no first-party page has this id.
        case notFirstParty(String)
        /// The root is not strictly inside the app's resources.
        case outsideBundle(String)
    }

    /// The agent pane's bundled page folder (`agent-pane`).
    @MainActor static var agentPaneRoot: URL? { AgentPaneView.bundledPage?.deletingLastPathComponent() }

    /// The bundled root of each first-party page that ships one.
    @MainActor static func bundledRoots() -> [String: URL] {
        var roots: [String: URL] = [:]
        roots[PageDescriptor.agent.id] = agentPaneRoot
        for page in [PageDescriptor.history, PageDescriptor.cloud] { roots[page.id] = page.pagesBundleRoot }
        return roots.filter { PageID.isFirstParty($0.key) }
    }

    /// Why `id` may not be served from `root`, nil when it may.
    static func refusal(id: String, root: URL, bundleResources: URL) -> Refusal? {
        guard PageID.isReserved(id) else { return .notReserved(id) }
        guard PageID.isFirstParty(id) else { return .notFirstParty(id) }
        guard isStrictlyInside(root, bundleResources) else { return .outsideBundle(id) }
        return nil
    }

    /// The entries of `roots` that pass ``refusal(id:root:bundleResources:)``.
    static func accepted(roots: [String: URL], bundleResources: URL) -> [String: URL] {
        roots.filter { refusal(id: $0.key, root: $0.value, bundleResources: bundleResources) == nil }
    }

    /// Hands the checked table to Chromium; call before Chromium starts.
    @MainActor static func install(bundle: Bundle = .main) {
        guard let resources = bundle.resourceURL else { return }
        CEFPageSchemes.firstPartyRoots = accepted(roots: bundledRoots(), bundleResources: resources)
    }

    /// Real paths, compared component by component (`Resources2` is not inside `Resources`).
    static func isStrictlyInside(_ url: URL, _ folder: URL) -> Bool {
        let inner = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let outer = folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return inner.count > outer.count && Array(inner.prefix(outer.count)) == outer
    }
}
