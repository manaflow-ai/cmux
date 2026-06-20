public import Bonsplit
public import Foundation

/// Owns the browser-panel creation orchestration the app-target `TabManager`
/// used to inline: the workspace resolution, the select-if-not-selected step,
/// the split-right reuse/split-source policy, the default focused-or-first-pane
/// open path, and the focus-memory bookkeeping.
///
/// The bodies are byte-faithful lifts of the former `TabManager.openBrowser`
/// (both overloads), `TabManager.newBrowserSplit(tabId:…)`, and
/// `TabManager.newBrowserSurface(tabId:…)`. Each resolves the target workspace
/// through ``BrowserOpenHosting`` and forwards the per-workspace creation
/// operations through ``BrowserOpenWorkspaceHandle``, receiving the created
/// panel's id. The app-side effects the legacy bodies performed (the
/// `BrowserAvailabilitySettings` gate, the
/// `selectWorkspaceId(_:notificationDismissalContext:)` selection flow with its
/// `AppDelegate.shared` notification-store dismissal, and the
/// `rememberFocusedSurface` write) stay app-side behind the host seam.
///
/// `@MainActor` because every entry point is one main-actor turn driven by a
/// keyboard shortcut, command palette, menu, or the command socket, and both the
/// host and the resolved workspace handle live there — co-locating removes any
/// bridging, the same isolation ruling as the sibling
/// ``FocusedBrowserController``.
@MainActor
public final class BrowserOpenCoordinator {
    private weak var host: (any BrowserOpenHosting)?

    /// Creates the coordinator. Call ``attach(host:)`` to wire the window-side
    /// host before driving any open path.
    public init() {}

    /// Attaches the window-side host that resolves workspaces and performs the
    /// app-coupled selection/focus-memory/availability effects.
    public func attach(host: any BrowserOpenHosting) {
        self.host = host
    }

    // MARK: - Open

    /// Opens a browser in a specific workspace, optionally preferring a
    /// split-right layout (legacy `openBrowser(inWorkspace:url:preferSplitRight:
    /// preferredProfileID:insertAtEnd:)`).
    @discardableResult
    public func openBrowser(
        inWorkspace tabId: UUID,
        url: URL? = nil,
        preferSplitRight: Bool = false,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard let host else { return nil }
        guard host.isBrowserEnabled else { return nil }
        guard let workspace = host.browserOpenWorkspaceHandle(forWorkspaceId: tabId) else { return nil }
        if host.selectedWorkspaceId != tabId {
            host.selectWorkspaceForBrowserOpen(tabId)
        }

        if preferSplitRight {
            if let targetPaneId = workspace.topRightBrowserReusePane(),
               let browserPanelId = workspace.newBrowserSurface(
                   inPane: targetPaneId,
                   url: url,
                   focus: true,
                   insertAtEnd: insertAtEnd,
                   preferredProfileID: preferredProfileID
               ) {
                host.rememberFocusedSurface(workspaceId: tabId, surfaceId: browserPanelId)
                return browserPanelId
            }

            let splitSourcePanelId: UUID? = {
                if let focusedPanelId = workspace.focusedPanelId,
                   workspace.hasPanel(focusedPanelId) {
                    return focusedPanelId
                }
                if let rememberedPanelId = host.rememberedFocusedPanelId(forWorkspaceId: tabId),
                   workspace.hasPanel(rememberedPanelId) {
                    return rememberedPanelId
                }
                if let orderedPanelId = workspace.sidebarOrderedPanelIds().first(where: { workspace.hasPanel($0) }) {
                    return orderedPanelId
                }
                return workspace.panelIdsSortedByUUIDString().first
            }()

            if let splitSourcePanelId,
               let browserPanelId = workspace.newBrowserSplit(
                   from: splitSourcePanelId,
                   orientation: .horizontal,
                   url: url,
                   preferredProfileID: preferredProfileID,
                   focus: true
               ) {
                host.rememberFocusedSurface(workspaceId: tabId, surfaceId: browserPanelId)
                return browserPanelId
            }
        }

        guard let paneId = workspace.focusedOrFirstPaneId,
              let browserPanelId = workspace.newBrowserSurface(
                  inPane: paneId,
                  url: url,
                  focus: true,
                  insertAtEnd: insertAtEnd,
                  preferredProfileID: preferredProfileID
              ) else {
            return nil
        }
        host.rememberFocusedSurface(workspaceId: tabId, surfaceId: browserPanelId)
        return browserPanelId
    }

    /// Opens a browser in the currently selected workspace (legacy
    /// `openBrowser(url:preferredProfileID:insertAtEnd:)`).
    @discardableResult
    public func openBrowser(
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        insertAtEnd: Bool = false
    ) -> UUID? {
        guard let host, let tabId = host.selectedWorkspaceId else { return nil }
        return openBrowser(
            inWorkspace: tabId,
            url: url,
            preferSplitRight: false,
            preferredProfileID: preferredProfileID,
            insertAtEnd: insertAtEnd
        )
    }

    // MARK: - Split / surface wrappers

    /// Creates a new browser panel in a split within `tabId` (legacy
    /// `newBrowserSplit(tabId:fromPanelId:orientation:insertFirst:url:
    /// preferredProfileID:focus:initialDividerPosition:)`).
    public func newBrowserSplit(
        tabId: UUID,
        fromPanelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        focus: Bool = true,
        initialDividerPosition: CGFloat? = nil
    ) -> UUID? {
        guard let host else { return nil }
        guard host.isBrowserEnabled else { return nil }
        guard let workspace = host.browserOpenWorkspaceHandle(forWorkspaceId: tabId) else { return nil }
        return workspace.newBrowserSplit(
            from: fromPanelId,
            orientation: orientation,
            insertFirst: insertFirst,
            url: url,
            preferredProfileID: preferredProfileID,
            focus: focus,
            initialDividerPosition: initialDividerPosition
        )
    }

    /// Creates a new browser surface in `paneId` within `tabId` (legacy
    /// `newBrowserSurface(tabId:inPane:url:preferredProfileID:)`).
    public func newBrowserSurface(
        tabId: UUID,
        inPane paneId: PaneID,
        url: URL? = nil,
        preferredProfileID: UUID? = nil
    ) -> UUID? {
        guard let host else { return nil }
        guard host.isBrowserEnabled else { return nil }
        guard let workspace = host.browserOpenWorkspaceHandle(forWorkspaceId: tabId) else { return nil }
        return workspace.newBrowserSurface(
            inPane: paneId,
            url: url,
            preferredProfileID: preferredProfileID
        )
    }
}
