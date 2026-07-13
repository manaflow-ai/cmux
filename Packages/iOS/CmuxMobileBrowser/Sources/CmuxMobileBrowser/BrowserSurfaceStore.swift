public import Foundation
import Observation
#if canImport(WebKit)
public import WebKit
#endif

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

    /// Equality-filtered, per-workspace values read by lazy-grid consumers.
    private var snapshotSourcesByWorkspace: [String: BrowserSurfaceSnapshotSource]

    /// Value snapshots used for copy-on-write persistence handoff.
    private var durableSnapshotsByWorkspace: [String: BrowserSurfaceSnapshot]

    /// Stable keys from the latest authoritative workspace list. An alias that
    /// is itself canonical belongs to that workspace and must not be borrowed.
    private var canonicalWorkspaceIDs: Set<String>

    /// Produces a fresh, unique surface id. Injected so tests are deterministic.
    private let makeSurfaceID: () -> BrowserSurfaceState.ID

    /// The URL a freshly opened browser loads. Injected so the default is
    /// configurable and tests stay hermetic.
    private let defaultURL: URL?

    /// Process persistence owner shared without sharing live scene state.
    private let persistenceCoordinator: BrowserSurfacePersistenceCoordinator

    /// Stable identity for this scene's independent archive contribution.
    private let persistenceClientID: UUID

    /// The authenticated owner allowed to read and write the persisted archive.
    private var persistenceScope: BrowserPersistenceScope?

    #if canImport(WebKit)
    /// The account-and-team-isolated WebKit storage container for new browser views.
    public private(set) var websiteDataStore: WKWebsiteDataStore
    #endif

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
    ///   - persistenceCoordinator: An optional process persistence owner shared
    ///     by distinct scene stores.
    public init(
        defaultURL: URL? = URL(string: "https://duckduckgo.com/"),
        makeSurfaceID: @escaping () -> BrowserSurfaceState.ID = {
            BrowserSurfaceState.ID(rawValue: UUID().uuidString)
        },
        persistenceDefaults: UserDefaults? = nil,
        persistenceKey: String = "cmux.mobile.browserSurfaces.v1",
        persistenceCoordinator: BrowserSurfacePersistenceCoordinator? = nil
    ) {
        self.makeSurfaceID = makeSurfaceID
        self.defaultURL = defaultURL
        self.persistenceCoordinator = persistenceCoordinator
            ?? BrowserSurfacePersistenceCoordinator(
                defaults: persistenceDefaults,
                archiveKey: persistenceKey
            )
        self.persistenceClientID = UUID()
        self.surfacesByWorkspace = [:]
        self.selectedBrowserWorkspaceIDs = []
        self.snapshotSourcesByWorkspace = [:]
        self.durableSnapshotsByWorkspace = [:]
        self.canonicalWorkspaceIDs = []
        self.persistenceScope = nil
        self.scheduledPersistenceTask = nil
        #if canImport(WebKit)
        self.websiteDataStore = .nonPersistent()
        #endif
    }

    isolated deinit {
        scheduledPersistenceTask?.cancel()
        persistenceCoordinator.unregister(clientID: persistenceClientID)
    }

    /// Moves durable browser state to a new authenticated account and team.
    ///
    /// Every real transition clears live browser references synchronously. The
    /// prior owner's archive is deleted, and restoration succeeds only when the
    /// persisted archive declares the exact new owner. Passing `nil` keeps any
    /// subsequently opened browsers memory-only.
    ///
    /// - Parameter newScope: The authenticated owner, or `nil` while signed out.
    public func setPersistenceScope(_ newScope: BrowserPersistenceScope?) {
        guard newScope != persistenceScope else { return }
        scheduledPersistenceTask?.cancel()
        scheduledPersistenceTask = nil
        hasPendingPersistence = false
        surfacesByWorkspace.removeAll()
        selectedBrowserWorkspaceIDs.removeAll()
        snapshotSourcesByWorkspace.removeAll()
        durableSnapshotsByWorkspace.removeAll()
        canonicalWorkspaceIDs.removeAll()
        persistenceScope = newScope
        #if canImport(WebKit)
        websiteDataStore = persistenceCoordinator.websiteDataStore(for: newScope)
        #endif
        let restoredSnapshots = persistenceCoordinator.setScope(
            newScope,
            for: persistenceClientID
        )
        guard newScope != nil else { return }
        restorePersistedSurfaces(from: restoredSnapshots)
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

    /// The reduced immutable browser value used at lazy collection boundaries.
    ///
    /// Reads observe only this workspace's equality-filtered snapshot source;
    /// WebKit loading and progress changes do not invalidate grid cards.
    ///
    /// - Parameter workspace: The workspace's stable identity.
    /// - Returns: Its retained browser snapshot, or `nil` when none is open.
    public func browserSnapshot(for workspace: BrowserWorkspaceIdentity) -> BrowserSurfaceSnapshot? {
        guard let key = existingKey(for: workspace) else { return nil }
        return snapshotSourcesByWorkspace[key]?.value
    }

    /// Compatibility overload for callers whose workspace identity is durable.
    public func browserSnapshot(for workspaceID: String) -> BrowserSurfaceSnapshot? {
        browserSnapshot(for: BrowserWorkspaceIdentity(rawValue: workspaceID))
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
            if existingKey != workspace.rawValue {
                migrateBrowserIfNeeded(from: existingKey, to: workspace.rawValue)
            }
            selectedBrowserWorkspaceIDs.insert(workspace.rawValue)
            refreshSnapshot(workspaceID: workspace.rawValue, surface: existing)
            persistImmediately()
            return existing
        }
        let surface = BrowserSurfaceState(id: makeSurfaceID(), initialURL: defaultURL)
        surfacesByWorkspace[workspace.rawValue] = surface
        selectedBrowserWorkspaceIDs.insert(workspace.rawValue)
        refreshSnapshot(workspaceID: workspace.rawValue, surface: surface)
        installPersistenceCallback(on: surface, workspaceID: workspace.rawValue)
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
        refreshSnapshot(workspaceID: key, surface: surfacesByWorkspace[key])
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
        snapshotSourcesByWorkspace.removeValue(forKey: key)
        durableSnapshotsByWorkspace.removeValue(forKey: key)
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
        let canonicalWorkspaceIDs = Set(workspaces.map(\.rawValue))
        self.canonicalWorkspaceIDs = canonicalWorkspaceIDs
        let aliasClaimCounts = workspaces.reduce(into: [String: Int]()) { counts, workspace in
            for alias in workspace.aliases {
                counts[alias, default: 0] += 1
            }
        }
        var didChange = false
        for (alias, count) in aliasClaimCounts
        where count > 1 && !canonicalWorkspaceIDs.contains(alias) {
            if surfacesByWorkspace.removeValue(forKey: alias) != nil {
                selectedBrowserWorkspaceIDs.remove(alias)
                snapshotSourcesByWorkspace.removeValue(forKey: alias)
                durableSnapshotsByWorkspace.removeValue(forKey: alias)
                didChange = true
            }
        }
        var validWorkspaceIDs = Set<String>()
        for workspace in workspaces.sorted(by: { $0.rawValue < $1.rawValue }) {
            if surfacesByWorkspace[workspace.rawValue] == nil,
               let alias = workspace.aliases.sorted().first(where: {
                   aliasClaimCounts[$0] == 1
                       && !canonicalWorkspaceIDs.contains($0)
                       && surfacesByWorkspace[$0] != nil
               }) {
                migrateBrowserIfNeeded(from: alias, to: workspace.rawValue)
                didChange = true
            }
            validWorkspaceIDs.insert(workspace.rawValue)
        }
        let removedWorkspaceIDs = surfacesByWorkspace.keys.filter { !validWorkspaceIDs.contains($0) }
        for workspaceID in removedWorkspaceIDs {
            surfacesByWorkspace.removeValue(forKey: workspaceID)
            selectedBrowserWorkspaceIDs.remove(workspaceID)
            snapshotSourcesByWorkspace.removeValue(forKey: workspaceID)
            durableSnapshotsByWorkspace.removeValue(forKey: workspaceID)
            didChange = true
        }
        guard didChange else { return }
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
        return workspace.aliases.sorted().first {
            !canonicalWorkspaceIDs.contains($0) && surfacesByWorkspace[$0] != nil
        }
    }

    private func migrateBrowserIfNeeded(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, surfacesByWorkspace[newKey] == nil,
              let surface = surfacesByWorkspace.removeValue(forKey: oldKey) else { return }
        surfacesByWorkspace[newKey] = surface
        let source = snapshotSourcesByWorkspace.removeValue(forKey: oldKey)
        durableSnapshotsByWorkspace.removeValue(forKey: oldKey)
        snapshotSourcesByWorkspace[newKey] = source ?? BrowserSurfaceSnapshotSource(
            value: makeSnapshot(workspaceID: newKey, surface: surface)
        )
        if selectedBrowserWorkspaceIDs.remove(oldKey) != nil {
            selectedBrowserWorkspaceIDs.insert(newKey)
        }
        installPersistenceCallback(on: surface, workspaceID: newKey)
        refreshSnapshot(workspaceID: newKey, surface: surface)
    }

    /// Remove every retained browser when the signed-in workspace scope ends.
    public func removeAllBrowsers() {
        scheduledPersistenceTask?.cancel()
        scheduledPersistenceTask = nil
        hasPendingPersistence = false
        surfacesByWorkspace.removeAll()
        selectedBrowserWorkspaceIDs.removeAll()
        snapshotSourcesByWorkspace.removeAll()
        durableSnapshotsByWorkspace.removeAll()
        canonicalWorkspaceIDs.removeAll()
        enqueuePersistence()
    }

    private func installPersistenceCallbacks() {
        for (workspaceID, surface) in surfacesByWorkspace {
            installPersistenceCallback(on: surface, workspaceID: workspaceID)
        }
    }

    private func installPersistenceCallback(on surface: BrowserSurfaceState, workspaceID: String) {
        surface.installPersistence { [weak self, weak surface] immediately in
            guard let self, let surface,
                  self.surfacesByWorkspace[workspaceID] === surface else { return }
            self.refreshSnapshot(workspaceID: workspaceID, surface: surface)
            if immediately {
                self.persistImmediately()
            } else {
                self.schedulePersistence()
            }
        }
    }

    private func restorePersistedSurfaces(
        from snapshotsByWorkspace: [String: BrowserSurfaceSnapshot]
    ) {
        // Decode into the workspace-keyed source of truth. Duplicate rows from
        // an interrupted or older writer cannot create duplicate browser cards;
        // the first valid persisted association wins deterministically.
        for snapshot in snapshotsByWorkspace.values
        where surfacesByWorkspace[snapshot.workspaceID] == nil {
            let restoredURL = snapshot.currentURL.flatMap(URL.init(string:))
            let surface = BrowserSurfaceState(
                id: .init(rawValue: snapshot.surfaceID),
                initialURL: restoredURL
            )
            surface.title = snapshot.title
            surface.contentModePreference = BrowserContentModePreference(persistenceRawValue: snapshot.contentMode)
            surfacesByWorkspace[snapshot.workspaceID] = surface
            if snapshot.isSelected {
                selectedBrowserWorkspaceIDs.insert(snapshot.workspaceID)
            }
            snapshotSourcesByWorkspace[snapshot.workspaceID] = BrowserSurfaceSnapshotSource(value: snapshot)
            durableSnapshotsByWorkspace[snapshot.workspaceID] = snapshot
        }
    }

    private func persistImmediately() {
        scheduledPersistenceTask?.cancel()
        scheduledPersistenceTask = nil
        hasPendingPersistence = false
        enqueuePersistence()
    }

    private func schedulePersistence() {
        guard persistenceScope != nil else { return }
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
                self.enqueuePersistence()
                guard self.hasPendingPersistence else {
                    self.scheduledPersistenceTask = nil
                    return
                }
            }
        }
    }

    private func enqueuePersistence() {
        persistenceCoordinator.replaceSnapshots(
            durableSnapshotsByWorkspace,
            for: persistenceClientID,
            scope: persistenceScope
        )
    }

    /// Waits until archive requests already submitted by this store finish.
    ///
    /// This is useful at explicit durability boundaries and in persistence tests;
    /// normal UI updates never wait for JSON encoding or defaults I/O.
    func flushPersistence() async {
        await persistenceCoordinator.flush()
    }

    private func makeSnapshot(workspaceID: String, surface: BrowserSurfaceState) -> BrowserSurfaceSnapshot {
        BrowserSurfaceSnapshot(
            workspaceID: workspaceID,
            surfaceID: surface.id.rawValue,
            currentURL: surface.currentURL?.absoluteString,
            title: surface.title,
            contentMode: surface.contentModePreference.persistenceRawValue,
            isSelected: selectedBrowserWorkspaceIDs.contains(workspaceID)
        )
    }

    private func refreshSnapshot(workspaceID: String, surface: BrowserSurfaceState?) {
        guard let surface else { return }
        let snapshot = makeSnapshot(workspaceID: workspaceID, surface: surface)
        durableSnapshotsByWorkspace[workspaceID] = snapshot
        if let source = snapshotSourcesByWorkspace[workspaceID] {
            source.update(snapshot)
        } else {
            snapshotSourcesByWorkspace[workspaceID] = BrowserSurfaceSnapshotSource(value: snapshot)
        }
    }
}
