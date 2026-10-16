public import Foundation
import Observation

/// Owns the phone-local browser surfaces, one optional active surface per
/// workspace.
///
/// Browser state is deliberately kept out of `MobileShellComposite` and
/// `MobileWorkspacePreview`: a terminal preview is rebuilt from the Mac on every
/// `workspace.updated` sync, so storing a browser there would clobber it on the
/// next sync. This store is the local home for browser panes; it is injected
/// into the shell UI alongside the terminal store and survives Mac re-syncs.
///
/// Each workspace has at most one browser surface in P1 (single pane, not
/// multi-tab). Opening a browser sets the workspace's active surface; closing it
/// clears it and the UI falls back to the terminal.
@MainActor
@Observable
public final class BrowserSurfaceStore {
    /// The active browser surface per workspace id, keyed by the workspace's raw
    /// identifier string. Absent keys mean the workspace shows its terminal.
    private var surfacesByWorkspace: [String: BrowserSurfaceState]

    /// Produces a fresh, unique surface id. Injected so tests are deterministic.
    private let makeSurfaceID: () -> BrowserSurfaceState.ID

    /// The URL a freshly opened browser loads. Injected so the default is
    /// configurable and tests stay hermetic.
    private let defaultURL: URL?

    /// Creates a browser surface store.
    ///
    /// - Parameters:
    ///   - defaultURL: The URL a newly opened browser loads. Defaults to
    ///     DuckDuckGo's homepage.
    ///   - makeSurfaceID: A factory for unique surface ids. Defaults to a
    ///     UUID-backed generator.
    public init(
        defaultURL: URL? = URL(string: "https://duckduckgo.com/"),
        makeSurfaceID: @escaping () -> BrowserSurfaceState.ID = {
            BrowserSurfaceState.ID(rawValue: UUID().uuidString)
        }
    ) {
        self.surfacesByWorkspace = [:]
        self.makeSurfaceID = makeSurfaceID
        self.defaultURL = defaultURL
    }

    /// The active browser surface for a workspace, if one is open.
    ///
    /// - Parameter workspaceID: The workspace's raw identifier string.
    /// - Returns: The active surface, or `nil` when the workspace shows its
    ///   terminal.
    public func activeBrowser(for workspaceID: String) -> BrowserSurfaceState? {
        surfacesByWorkspace[workspaceID]
    }

    /// Whether a workspace currently has a browser pane open.
    ///
    /// - Parameter workspaceID: The workspace's raw identifier string.
    /// - Returns: `true` if a browser surface is active for the workspace.
    public func hasBrowser(for workspaceID: String) -> Bool {
        surfacesByWorkspace[workspaceID] != nil
    }

    /// Open (or reveal the existing) browser pane for a workspace.
    ///
    /// If the workspace already has a browser surface, that same surface is
    /// returned so the current page is restored when switching away and back
    /// (the surface's `currentURL` is reloaded into a fresh web view on
    /// re-attach). In P1, full back/forward history is not preserved across
    /// remounts; persisting the live WebKit session and history is P2. A new
    /// surface loads ``defaultURL``.
    ///
    /// - Parameter workspaceID: The workspace's raw identifier string.
    /// - Returns: The active browser surface for the workspace.
    @discardableResult
    public func openBrowser(for workspaceID: String) -> BrowserSurfaceState {
        if let existing = surfacesByWorkspace[workspaceID] {
            return existing
        }
        let surface = BrowserSurfaceState(id: makeSurfaceID(), initialURL: defaultURL)
        surfacesByWorkspace[workspaceID] = surface
        return surface
    }

    /// The phone-side browser of each streamed tab the user switched to "On
    /// iPhone", keyed by the tab's panel id. The choice and the page belong
    /// to each tab: while a tab is On iPhone, this surface (not the Mac tab's
    /// URL) is the source of truth, so leaving the tab and coming back shows
    /// the page last loaded on the phone.
    private var onDeviceSurfacesByPanel: [String: BrowserSurfaceState] = [:]

    /// Whether the streamed tab `panelID` was last switched to "On iPhone".
    public func prefersOnDevice(panelID: String) -> Bool {
        onDeviceSurfacesByPanel[panelID] != nil
    }

    /// Shows streamed tab `panelID` "On iPhone" in a workspace and remembers
    /// that mode for the tab.
    ///
    /// The tab's existing phone-side surface is revealed as is, so its last
    /// page is restored (a fresh web view reloads its `currentURL`). The
    /// first time, a new surface linked to the tab loads `url` (the Mac
    /// tab's page), or ``defaultURL`` when that is not a web page.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace's raw identifier string.
    ///   - panelID: The streamed tab's panel id.
    ///   - url: The Mac tab's current URL.
    /// - Returns: The workspace's active browser surface, linked to the tab.
    @discardableResult
    public func openOnDevice(for workspaceID: String, panelID: String, url: URL?) -> BrowserSurfaceState {
        if let existing = onDeviceSurfacesByPanel[panelID] {
            surfacesByWorkspace[workspaceID] = existing
            return existing
        }
        let webURL = url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let surface = BrowserSurfaceState(id: makeSurfaceID(), initialURL: webURL ?? defaultURL)
        surface.linkedStreamPanelID = panelID
        onDeviceSurfacesByPanel[panelID] = surface
        surfacesByWorkspace[workspaceID] = surface
        return surface
    }

    /// Forgets streamed tab `panelID`'s "On iPhone" mode and page, so it
    /// opens streamed again.
    public func forgetOnDevice(panelID: String) {
        onDeviceSurfacesByPanel[panelID] = nil
    }

    /// Close the browser pane for a workspace, returning the UI to its terminal.
    /// A streamed tab's "On iPhone" surface stays remembered for that tab.
    ///
    /// - Parameter workspaceID: The workspace's raw identifier string.
    public func closeBrowser(for workspaceID: String) {
        surfacesByWorkspace.removeValue(forKey: workspaceID)
    }
}
