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

    /// Coalesces page-controlled same-document URL churn into bounded durable
    /// writes instead of serializing every retained surface for every callback.
    private var scheduledPersistenceTask: Task<Void, Never>?
    private var hasPendingPersistence = false
    private static let persistenceCoalescingInterval: Duration = .milliseconds(250)

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
        self.scheduledPersistenceTask = nil

        restorePersistedSurfaces()
        installPersistenceCallbacks()
    }

    /// The active browser surface for a workspace, if one is open.
    ///
    /// - Parameter workspace: The workspace's stable identity and any legacy aliases.
    /// - Returns: The active surface, or `nil` when the workspace shows its
    ///   terminal.
    public func activeBrowser(for workspace: BrowserWorkspaceIdentity) -> BrowserSurfaceState? {
        guard let key = existingKey(for: workspace), selectedBrowserWorkspaceIDs.contains(key) else { return nil }
        return surfacesByWorkspace[key]
    }

    /// Compatibility overload for callers whose workspace identity is already a
    /// durable string.
    public func activeBrowser(for workspaceID: String) -> BrowserSurfaceState? {
        activeBrowser(for: BrowserWorkspaceIdentity(rawValue: workspaceID))
    }

    /// The workspace's browser whether it is selected or currently hidden by a
    /// terminal surface.
    ///
    /// - Parameter workspace: The workspace's stable identity and any legacy aliases.
    /// - Returns: The retained local browser, or `nil` when none has been opened.
    public func browser(for workspace: BrowserWorkspaceIdentity) -> BrowserSurfaceState? {
        existingKey(for: workspace).flatMap { surfacesByWorkspace[$0] }
    }

    /// Compatibility overload for callers whose workspace identity is already a
    /// durable string.
    public func browser(for workspaceID: String) -> BrowserSurfaceState? {
        browser(for: BrowserWorkspaceIdentity(rawValue: workspaceID))
    }

    /// Whether a workspace currently has a browser pane open.
    ///
    /// - Parameter workspace: The workspace's stable identity and any legacy aliases.
    /// - Returns: `true` if a browser surface is active for the workspace.
    public func hasBrowser(for workspace: BrowserWorkspaceIdentity) -> Bool {
        existingKey(for: workspace) != nil
    }

    /// Compatibility overload for callers whose workspace identity is already a
    /// durable string.
    public func hasBrowser(for workspaceID: String) -> Bool {
        hasBrowser(for: BrowserWorkspaceIdentity(rawValue: workspaceID))
    }

    /// Whether the workspace's retained browser is the selected surface.
    ///
    /// - Parameter workspace: The workspace's stable identity and any legacy aliases.
    public func isBrowserSelected(for workspace: BrowserWorkspaceIdentity) -> Bool {
        activeBrowser(for: workspace) != nil
    }

    /// Compatibility overload for callers whose workspace identity is already a
    /// durable string.
    public func isBrowserSelected(for workspaceID: String) -> Bool {
        isBrowserSelected(for: BrowserWorkspaceIdentity(rawValue: workspaceID))
    }

    /// Open (or reveal the existing) browser pane for a workspace.
    ///
    /// If the workspace already has a browser surface, that same surface is
    /// returned so the current page is restored when switching away and back
    /// (the surface's saved WebKit interaction state, including the page and
    /// back/forward stack, is restored into a fresh web view on re-attach, with
    /// `currentURL` as the fallback). A new surface loads ``defaultURL``.
    ///
    /// - Parameter workspace: The workspace's stable identity and any legacy aliases.
    /// - Returns: The active browser surface for the workspace.
    @discardableResult
    public func openBrowser(for workspace: BrowserWorkspaceIdentity) -> BrowserSurfaceState {
        if let existingKey = existingKey(for: workspace),
           let existing = surfacesByWorkspace[existingKey] {
            migrateBrowserIfNeeded(from: existingKey, to: workspace.rawValue)
            selectedBrowserWorkspaceIDs.insert(workspace.rawValue)
            persistImmediately()
            return existing
        }
        let surface = BrowserSurfaceState(id: makeSurfaceID(), initialURL: defaultURL)
        surfacesByWorkspace[workspace.rawValue] = surface
        selectedBrowserWorkspaceIDs.insert(workspace.rawValue)
        installPersistenceCallback(on: surface)
        persistImmediately()
        return surface
    }

    /// Compatibility overload for callers whose workspace identity is already a
    /// durable string.
    @discardableResult
    public func openBrowser(for workspaceID: String) -> BrowserSurfaceState {
        openBrowser(for: BrowserWorkspaceIdentity(rawValue: workspaceID))
    }

    /// Select a terminal or chat surface without destroying the workspace's
    /// retained local browser.
    ///
    /// - Parameter workspace: The workspace's stable identity and any legacy aliases.
    public func showNonBrowserSurface(for workspace: BrowserWorkspaceIdentity) {
        guard let key = existingKey(for: workspace),
              selectedBrowserWorkspaceIDs.remove(key) != nil else { return }
        persistImmediately()
    }

    /// Compatibility overload for callers whose workspace identity is already a
    /// durable string.
    public func showNonBrowserSurface(for workspaceID: String) {
        showNonBrowserSurface(for: BrowserWorkspaceIdentity(rawValue: workspaceID))
    }

    /// Close the browser pane for a workspace, returning the UI to its terminal.
    ///
    /// - Parameter workspace: The workspace's stable identity and any legacy aliases.
    public func closeBrowser(for workspace: BrowserWorkspaceIdentity) {
        guard let key = existingKey(for: workspace) else { return }
        surfacesByWorkspace.removeValue(forKey: key)
        selectedBrowserWorkspaceIDs.remove(key)
        persistImmediately()
    }

    /// Compatibility overload for callers whose workspace identity is already a
    /// durable string.
    public func closeBrowser(for workspaceID: String) {
        closeBrowser(for: BrowserWorkspaceIdentity(rawValue: workspaceID))
    }

    /// Remove browser surfaces whose authoritative workspace no longer exists.
    ///
    /// - Parameter workspaces: The complete authoritative stable workspace identity set.
    public func reconcileWorkspaces(_ workspaces: [BrowserWorkspaceIdentity]) {
        var validWorkspaceIDs = Set<String>()
        for workspace in workspaces.sorted(by: { $0.rawValue < $1.rawValue }) {
            if surfacesByWorkspace[workspace.rawValue] == nil,
               let alias = existingAlias(for: workspace) {
                migrateBrowserIfNeeded(from: alias, to: workspace.rawValue)
            }
            validWorkspaceIDs.insert(workspace.rawValue)
        }
        let removedWorkspaceIDs = surfacesByWorkspace.keys.filter { !validWorkspaceIDs.contains($0) }
        guard !removedWorkspaceIDs.isEmpty else { return }
        for workspaceID in removedWorkspaceIDs {
            surfacesByWorkspace.removeValue(forKey: workspaceID)
            selectedBrowserWorkspaceIDs.remove(workspaceID)
        }
        persistImmediately()
    }

    /// Compatibility overload for callers that already hold durable string keys.
    public func reconcileWorkspaces<WorkspaceIDs: Sequence>(_ workspaceIDs: WorkspaceIDs)
    where WorkspaceIDs.Element == String {
        reconcileWorkspaces(workspaceIDs.map { BrowserWorkspaceIdentity(rawValue: $0) })
    }

    private func existingKey(for workspace: BrowserWorkspaceIdentity) -> String? {
        if surfacesByWorkspace[workspace.rawValue] != nil {
            return workspace.rawValue
        }
        return existingAlias(for: workspace)
    }

    private func existingAlias(for workspace: BrowserWorkspaceIdentity) -> String? {
        workspace.aliases.sorted().first { surfacesByWorkspace[$0] != nil }
    }

    private func migrateBrowserIfNeeded(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, surfacesByWorkspace[newKey] == nil,
              let surface = surfacesByWorkspace.removeValue(forKey: oldKey) else { return }
        surfacesByWorkspace[newKey] = surface
        if selectedBrowserWorkspaceIDs.remove(oldKey) != nil {
            selectedBrowserWorkspaceIDs.insert(newKey)
        }
    }

    /// Remove every retained browser when the signed-in workspace scope ends.
    public func removeAllBrowsers() {
        guard !surfacesByWorkspace.isEmpty || !selectedBrowserWorkspaceIDs.isEmpty else { return }
        surfacesByWorkspace.removeAll()
        selectedBrowserWorkspaceIDs.removeAll()
        persistImmediately()
    }

    private func installPersistenceCallbacks() {
        for surface in surfacesByWorkspace.values {
            installPersistenceCallback(on: surface)
        }
    }

    private func installPersistenceCallback(on surface: BrowserSurfaceState) {
        surface.installPersistence { [weak self] immediately in
            if immediately {
                self?.persistImmediately()
            } else {
                self?.schedulePersistence()
            }
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

    private func persistImmediately() {
        scheduledPersistenceTask?.cancel()
        scheduledPersistenceTask = nil
        hasPendingPersistence = false
        persist()
    }

    private func schedulePersistence() {
        guard persistenceDefaults != nil else { return }
        hasPendingPersistence = true
        guard scheduledPersistenceTask == nil else { return }
        scheduledPersistenceTask = Task { @MainActor [weak self] in
            while let self {
                self.hasPendingPersistence = false
                do {
                    try await ContinuousClock().sleep(for: Self.persistenceCoalescingInterval)
                } catch {
                    return
                }
                self.persist()
                guard self.hasPendingPersistence else {
                    self.scheduledPersistenceTask = nil
                    return
                }
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

    private func contentModePreference(_ rawValue: String) -> BrowserContentModePreference {
        switch rawValue {
        case "mobile": .mobile
        case "desktop": .desktop
        default: .recommended
        }
    }

    private func contentModeRawValue(_ preference: BrowserContentModePreference) -> String {
        switch preference {
        case .recommended: "recommended"
        case .mobile: "mobile"
        case .desktop: "desktop"
        }
    }
}
