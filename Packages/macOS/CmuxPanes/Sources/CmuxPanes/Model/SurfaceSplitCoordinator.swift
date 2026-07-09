public import Bonsplit
public import Foundation

/// Owns the surface-navigation, split-creation, and split-operation orchestration
/// the app-target `TabManager` used to inline: the `selectedWorkspace` /
/// `tabs.first(where:)` workspace resolution, the focused-panel / panel-existence
/// guards, the `clearSplitZoom` + `newTerminalSplit` creation sequence, and the
/// divider-resize math (delegated to ``PaneLayoutService``).
///
/// The bodies are byte-faithful lifts of the former `TabManager`
/// `selectNextSurface`/`selectPreviousSurface`/`selectSurface(at:)`/
/// `selectLastSurface`/`newSurface`/`newSurface(initialInput:)`,
/// `createSplit(direction:)`/`createSplit(tabId:surfaceId:direction:focus:)`/
/// `newSplit(...)`, and `moveSplitFocus`/`resizeSplit`/`toggleSplitZoom`/
/// `toggleFocusedSplitZoom`/`closeSurface`. Each resolves the target workspace
/// through ``SurfaceSplitHosting`` and forwards the per-workspace operations
/// through ``SurfaceSplitWorkspaceHandle``. The app-side effects the legacy
/// bodies performed (the Sentry breadcrumb on split create and the
/// `AppDelegate.shared` notification-store clear after a close) stay app-side
/// behind the host seam. Browser splits (`createBrowserSplit`/`newBrowserSplit`)
/// are deliberately excluded — they live in `CmuxBrowser`'s
/// ``BrowserOpenCoordinator``.
///
/// `@MainActor` because every entry point is one main-actor turn driven by a
/// keyboard shortcut, command palette, menu, or the command socket, and both the
/// host and the resolved workspace handle live there — co-locating removes any
/// bridging, the same isolation ruling as the sibling ``BrowserOpenCoordinator``.
@MainActor
public final class SurfaceSplitCoordinator {
    private weak var host: (any SurfaceSplitHosting)?

    /// The stateless layout service the resize body delegates the divider math to
    /// (legacy `TabManager.paneLayout`).
    private let paneLayout = PaneLayoutService()

    /// Creates the coordinator. Call ``attach(host:)`` to wire the window-side
    /// host before driving any path.
    public init() {}

    /// Attaches the window-side host that resolves workspaces and performs the
    /// app-coupled breadcrumb/notification effects.
    public func attach(host: any SurfaceSplitHosting) {
        self.host = host
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane of the selected
    /// workspace (legacy `TabManager.selectNextSurface`).
    public func selectNextSurface() {
        host?.selectedSurfaceSplitWorkspaceHandle?.selectNextSurface()
    }

    /// Select the previous surface in the currently focused pane of the selected
    /// workspace (legacy `TabManager.selectPreviousSurface`).
    public func selectPreviousSurface() {
        host?.selectedSurfaceSplitWorkspaceHandle?.selectPreviousSurface()
    }

    /// Select a surface by index in the currently focused pane of the selected
    /// workspace (legacy `TabManager.selectSurface(at:)`).
    public func selectSurface(at index: Int) {
        host?.selectedSurfaceSplitWorkspaceHandle?.selectSurface(at: index)
    }

    /// Select the last surface in the currently focused pane of the selected
    /// workspace (legacy `TabManager.selectLastSurface`).
    public func selectLastSurface() {
        host?.selectedSurfaceSplitWorkspaceHandle?.selectLastSurface()
    }

    /// Create a new terminal surface in the focused pane of the selected
    /// workspace (legacy `TabManager.newSurface`).
    public func newSurface() {
        // Cmd+T should always focus the newly created surface.
        host?.selectedSurfaceSplitWorkspaceHandle?.clearSplitZoom()
        host?.selectedSurfaceSplitWorkspaceHandle?.surfaceSplitNewTerminalSurfaceInFocusedPane(focus: true, initialInput: nil)
    }

    /// Create a new terminal surface seeded with `initialInput` in the focused
    /// pane of the selected workspace (legacy
    /// `TabManager.newSurface(initialInput:)`).
    public func newSurface(initialInput: String) {
        host?.selectedSurfaceSplitWorkspaceHandle?.clearSplitZoom()
        host?.selectedSurfaceSplitWorkspaceHandle?.surfaceSplitNewTerminalSurfaceInFocusedPane(focus: true, initialInput: initialInput)
    }

    // MARK: - Split Creation

    /// Create a new split in the current tab (legacy
    /// `TabManager.createSplit(direction:)`).
    @discardableResult
    public func createSplit(direction: SplitDirection) -> UUID? {
        guard let host,
              let selectedTabId = host.selectedWorkspaceId,
              let tab = host.surfaceSplitWorkspaceHandle(forWorkspaceId: selectedTabId),
              let focusedPanelId = tab.focusedPanelId else { return nil }
        return createSplit(tabId: selectedTabId, surfaceId: focusedPanelId, direction: direction)
    }

    /// Create a new split from an explicit source panel (legacy
    /// `TabManager.createSplit(tabId:surfaceId:direction:focus:)`).
    @discardableResult
    public func createSplit(tabId: UUID, surfaceId: UUID, direction: SplitDirection, focus: Bool = true) -> UUID? {
        guard let host,
              let tab = host.surfaceSplitWorkspaceHandle(forWorkspaceId: tabId),
              tab.hasPanel(surfaceId) else { return nil }
        tab.clearSplitZoom()
        host.recordSplitCreateBreadcrumb(direction: String(describing: direction))
        return newSplit(tabId: tabId, surfaceId: surfaceId, direction: direction, focus: focus)
    }

    // MARK: - Split Operations (Backwards Compatibility)

    /// Create a new split in the specified direction. Returns the new panel's ID
    /// (which is also the surface ID for terminals) (legacy
    /// `TabManager.newSplit(...)`).
    public func newSplit(
        tabId: UUID,
        surfaceId: UUID,
        direction: SplitDirection,
        focus: Bool = true,
        workingDirectory: String? = nil,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        startupEnvironment: [String: String] = [:],
        initialDividerPosition: CGFloat? = nil,
        remotePTYSessionID: String? = nil
    ) -> UUID? {
        guard let tab = host?.surfaceSplitWorkspaceHandle(forWorkspaceId: tabId) else { return nil }
        return tab.surfaceSplitNewTerminalSplit(
            from: surfaceId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            focus: focus,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            startupEnvironment: startupEnvironment,
            initialDividerPosition: initialDividerPosition,
            remotePTYSessionID: remotePTYSessionID
        )
    }

    /// Move focus in the specified direction (legacy
    /// `TabManager.moveSplitFocus`).
    public func moveSplitFocus(tabId: UUID, surfaceId: UUID, direction: NavigationDirection) -> Bool {
        guard let tab = host?.surfaceSplitWorkspaceHandle(forWorkspaceId: tabId) else { return false }
        tab.moveFocus(direction: direction)
        return true
    }

    /// Resize split - not directly supported by bonsplit, but we can adjust
    /// divider positions (legacy `TabManager.resizeSplit`).
    public func resizeSplit(tabId: UUID, surfaceId: UUID, direction: ResizeDirection, amount: UInt16) -> Bool {
        guard amount > 0,
              let tab = host?.surfaceSplitWorkspaceHandle(forWorkspaceId: tabId),
              let paneId = tab.paneId(forPanelId: surfaceId) else { return false }

        let paneUUID = paneId.id
        guard tab.bonsplitController.allPaneIds.contains(where: { $0.id == paneUUID }) else {
            return false
        }

        return paneLayout.resizeSplit(
            in: tab.bonsplitController.treeSnapshot(),
            targetPaneId: paneUUID.uuidString,
            direction: direction,
            amountPixels: amount,
            controller: tab.bonsplitController
        )
    }

    /// Toggle zoom on a panel (legacy `TabManager.toggleSplitZoom`).
    public func toggleSplitZoom(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = host?.surfaceSplitWorkspaceHandle(forWorkspaceId: tabId) else { return false }
        return tab.toggleSplitZoom(panelId: surfaceId)
    }

    /// Toggle zoom for the currently focused panel in the selected workspace
    /// (legacy `TabManager.toggleFocusedSplitZoom`).
    @discardableResult
    public func toggleFocusedSplitZoom() -> Bool {
        guard let tab = host?.selectedSurfaceSplitWorkspaceHandle,
              let focusedPanelId = tab.focusedPanelId else { return false }
        return tab.toggleSplitZoom(panelId: focusedPanelId)
    }

    /// Close a surface/panel (legacy `TabManager.closeSurface`).
    public func closeSurface(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let host, let tab = host.surfaceSplitWorkspaceHandle(forWorkspaceId: tabId) else { return false }
        // Guard against stale close callbacks (e.g. child-exit can trigger multiple actions).
        // A stale callback must never affect unrelated panels/workspaces.
        guard tab.hasPanel(surfaceId),
              tab.surfaceIdFromPanelId(surfaceId) != nil else { return false }
        tab.closePanel(surfaceId, force: false)
        host.clearNotifications(forWorkspaceId: tabId, surfaceId: surfaceId)
        return true
    }
}
