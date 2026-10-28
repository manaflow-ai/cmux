public import Foundation

/// Where an agent pane's page comes from: ``bundled(_:)``, the self-contained page that
/// `scripts/cmux-next/build-agent-pane-web.sh` builds into the module bundle. The page host
/// (``AgentPanePageHost``) serves its directory at `cmux-page://cmux.agent/`; a web-dev.json
/// overlay or an active web update swaps the files it serves (``WebDevOverride``), and a web-dev.json
/// server serves it from the webviews dev server's `/agent-pane/` with hot reload.
///
/// ```swift
/// let source = AgentPaneSource.resolve(environment: ProcessInfo.processInfo.environment,
///                                      bundledPage: AgentPaneView.bundledPage, allowsRootOverride: false)
/// ```
public nonisolated enum AgentPaneSource: Equatable, Sendable {
    /// The `index.html` the page host serves: the module bundle's, or a Debug build's override.
    case bundled(URL)

    /// The Debug override of the page's directory, the page host's variable for every first-party
    /// page (`CMUX_NEXT_PAGE_ROOT_<id>`, dots as underscores; agent-stream-e2e.py loads variants by it).
    public static let rootVariable = "CMUX_NEXT_PAGE_ROOT_cmux_agent"

    /// The page to load: the directory ``rootVariable`` names when `allowsRootOverride` (Debug
    /// builds), else the bundled page; nil when neither exists.
    public static func resolve(environment: [String: String], bundledPage: URL?, allowsRootOverride: Bool) -> AgentPaneSource? {
        if allowsRootOverride, let root = environment[rootVariable], !root.isEmpty {
            return .bundled(URL(fileURLWithPath: root, isDirectory: true).appending(path: "index.html"))
        }
        return bundledPage.map { .bundled($0) }
    }

    /// The directory that holds the page's `index.html`, the root the page host serves.
    public var directory: URL {
        switch self {
        case .bundled(let page): page.deletingLastPathComponent()
        }
    }
}
