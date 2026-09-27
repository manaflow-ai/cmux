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

    /// Close the browser pane for a workspace, returning the UI to its terminal.
    ///
    /// - Parameter workspaceID: The workspace's raw identifier string.
    public func closeBrowser(for workspaceID: String) {
        surfacesByWorkspace.removeValue(forKey: workspaceID)
    }
}
