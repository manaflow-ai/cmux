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
/// Each workspace has at most one browser surface (single pane, not multi-tab).
/// Selecting a terminal hides the browser without destroying it, so its WebKit
/// session can be restored when the browser card is selected again. Closing the
/// browser explicitly removes that workspace's surface.
@MainActor
@Observable
public final class BrowserSurfaceStore {
    /// The active browser surface per workspace id, keyed by the workspace's raw
    /// identifier string. Absent keys mean the workspace shows its terminal.
    private var surfacesByWorkspace: [String: BrowserSurfaceState]

    /// Workspace IDs whose browser is currently selected instead of a terminal.
    private var selectedBrowserWorkspaceIDs: Set<String>

    /// Produces a fresh, unique surface id. Injected so tests are deterministic.
    private let makeSurfaceID: () -> BrowserSurfaceState.ID

    /// The URL a freshly opened browser loads. Injected so the default is
    /// configurable and tests stay hermetic.
    private let defaultURL: URL?

    /// Optional durable storage. `nil` keeps tests and previews hermetic.
    private let persistenceDefaults: UserDefaults?

    /// UserDefaults key for the versioned snapshot array.
    private let persistenceKey: String

    /// Creates a browser surface store.
    ///
    /// - Parameters:
    ///   - defaultURL: The URL a newly opened browser loads. Defaults to
    ///     DuckDuckGo's homepage.
    ///   - makeSurfaceID: A factory for unique surface ids. Defaults to a
    ///     UUID-backed generator.
    ///   - persistenceDefaults: Optional defaults storage for cold-launch
    ///     restoration. Pass `.standard` at the app composition root.
    ///   - persistenceKey: The versioned defaults key.
    public init(
        defaultURL: URL? = URL(string: "https://duckduckgo.com/"),
        makeSurfaceID: @escaping () -> BrowserSurfaceState.ID = {
            BrowserSurfaceState.ID(rawValue: UUID().uuidString)
        },
        persistenceDefaults: UserDefaults? = nil,
        persistenceKey: String = "cmux.mobile.browserSurfaces.v1"
    ) {
        self.makeSurfaceID = makeSurfaceID
        self.defaultURL = defaultURL
        self.persistenceDefaults = persistenceDefaults
        self.persistenceKey = persistenceKey
        self.surfacesByWorkspace = [:]
        self.selectedBrowserWorkspaceIDs = []

        restorePersistedSurfaces()
        installPersistenceCallbacks()
    }

    /// The active browser surface for a workspace, if one is open.
    ///
    /// - Parameter workspaceID: The workspace's raw identifier string.
    /// - Returns: The active surface, or `nil` when the workspace shows its
    ///   terminal.
    public func activeBrowser(for workspaceID: String) -> BrowserSurfaceState? {
        guard selectedBrowserWorkspaceIDs.contains(workspaceID) else { return nil }
        return surfacesByWorkspace[workspaceID]
    }

    /// The workspace's browser whether it is selected or currently hidden by a
    /// terminal surface.
    ///
    /// - Parameter workspaceID: The workspace's raw identifier string.
    /// - Returns: The retained local browser, or `nil` when none has been opened.
    public func browser(for workspaceID: String) -> BrowserSurfaceState? {
        surfacesByWorkspace[workspaceID]
    }

    /// Whether a workspace currently has a browser pane open.
    ///
    /// - Parameter workspaceID: The workspace's raw identifier string.
    /// - Returns: `true` if a browser surface is active for the workspace.
    public func hasBrowser(for workspaceID: String) -> Bool {
        surfacesByWorkspace[workspaceID] != nil
    }

    /// Whether the workspace's retained browser is the selected surface.
    ///
    /// - Parameter workspaceID: The workspace's raw identifier string.
    public func isBrowserSelected(for workspaceID: String) -> Bool {
        activeBrowser(for: workspaceID) != nil
    }

    /// Open (or reveal the existing) browser pane for a workspace.
    ///
    /// If the workspace already has a browser surface, that same surface is
    /// returned so the current page is restored when switching away and back
    /// (the surface's saved WebKit interaction state, including the page and
    /// back/forward stack, is restored into a fresh web view on re-attach, with
    /// `currentURL` as the fallback). A new surface loads ``defaultURL``.
    ///
    /// - Parameter workspaceID: The workspace's raw identifier string.
    /// - Returns: The active browser surface for the workspace.
    @discardableResult
    public func openBrowser(for workspaceID: String) -> BrowserSurfaceState {
        if let existing = surfacesByWorkspace[workspaceID] {
            selectedBrowserWorkspaceIDs.insert(workspaceID)
            persist()
            return existing
        }
        let surface = BrowserSurfaceState(id: makeSurfaceID(), initialURL: defaultURL)
        surfacesByWorkspace[workspaceID] = surface
        selectedBrowserWorkspaceIDs.insert(workspaceID)
        installPersistenceCallback(on: surface)
        persist()
        return surface
    }

    /// Select a terminal or chat surface without destroying the workspace's
    /// retained local browser.
    ///
    /// - Parameter workspaceID: The workspace's raw identifier string.
    public func showNonBrowserSurface(for workspaceID: String) {
        guard selectedBrowserWorkspaceIDs.remove(workspaceID) != nil else { return }
        persist()
    }

    /// Close the browser pane for a workspace, returning the UI to its terminal.
    ///
    /// - Parameter workspaceID: The workspace's raw identifier string.
    public func closeBrowser(for workspaceID: String) {
        surfacesByWorkspace.removeValue(forKey: workspaceID)
        selectedBrowserWorkspaceIDs.remove(workspaceID)
        persist()
    }

    private func installPersistenceCallbacks() {
        for surface in surfacesByWorkspace.values {
            installPersistenceCallback(on: surface)
        }
    }

    private func installPersistenceCallback(on surface: BrowserSurfaceState) {
        surface.installPersistence { [weak self] in
            self?.persist()
        }
    }

    private func restorePersistedSurfaces() {
        guard let data = persistenceDefaults?.data(forKey: persistenceKey),
              let snapshots = try? JSONDecoder().decode([BrowserSurfaceSnapshot].self, from: data)
        else {
            return
        }

        // Decode into the workspace-keyed source of truth. Duplicate rows from
        // an interrupted or older writer cannot create duplicate browser cards;
        // the first valid persisted association wins deterministically.
        for snapshot in snapshots where surfacesByWorkspace[snapshot.workspaceID] == nil {
            let restoredURL = snapshot.currentURL.flatMap(URL.init(string:))
            let surface = BrowserSurfaceState(
                id: .init(rawValue: snapshot.surfaceID),
                initialURL: restoredURL
            )
            surface.title = snapshot.title
            surface.contentModePreference = contentModePreference(snapshot.contentMode)
            surfacesByWorkspace[snapshot.workspaceID] = surface
            if snapshot.isSelected {
                selectedBrowserWorkspaceIDs.insert(snapshot.workspaceID)
            }
        }
    }

    private func persist() {
        guard let persistenceDefaults else { return }
        let snapshots = surfacesByWorkspace.keys.sorted().compactMap { workspaceID -> BrowserSurfaceSnapshot? in
            guard let surface = surfacesByWorkspace[workspaceID] else { return nil }
            return BrowserSurfaceSnapshot(
                workspaceID: workspaceID,
                surfaceID: surface.id.rawValue,
                currentURL: surface.currentURL?.absoluteString,
                title: surface.title,
                contentMode: contentModeRawValue(surface.contentModePreference),
                isSelected: selectedBrowserWorkspaceIDs.contains(workspaceID)
            )
        }
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        persistenceDefaults.set(data, forKey: persistenceKey)
    }

    private func contentModePreference(_ rawValue: String) -> BrowserSurfaceState.ContentModePreference {
        switch rawValue {
        case "mobile": .mobile
        case "desktop": .desktop
        default: .recommended
        }
    }

    private func contentModeRawValue(_ preference: BrowserSurfaceState.ContentModePreference) -> String {
        switch preference {
        case .recommended: "recommended"
        case .mobile: "mobile"
        case .desktop: "desktop"
        }
    }
}
