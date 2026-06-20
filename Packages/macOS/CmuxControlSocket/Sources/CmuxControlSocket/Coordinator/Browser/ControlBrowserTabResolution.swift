public import Foundation

/// The outcome of `browser.tab.list`, the typed twin of the legacy
/// `TerminalController.v2BrowserTabList(params:)` body.
///
/// The witness reproduces the `v2ResolveTabManager` → `v2ResolveWorkspace` head
/// and enumerates the workspace's ordered `BrowserPanel`s; the coordinator shapes
/// the identity payload plus the `tabs` array. Each tab row carries the legacy
/// keys exactly: `id`, `ref`, `index`, `title`, `url`, `focused`, `pane_id`,
/// `pane_ref`.
public enum ControlBrowserTabListResolution: Sendable, Equatable {
    /// `v2ResolveTabManager` returned nil
    /// (`unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// `v2ResolveWorkspace` returned nil
    /// (`not_found` / "Workspace not found").
    case workspaceNotFound
    /// Resolved: the owning workspace, its focused surface (if any), and the
    /// ordered browser-tab rows.
    case resolved(workspaceID: UUID, focusedSurfaceID: UUID?, tabs: [ControlBrowserTabRow])
}

/// One row of `browser.tab.list`, the typed twin of a legacy tab dictionary.
///
/// `paneID` is the resolved owning pane (the legacy `ws.paneId(forPanelId:)`),
/// nil when the panel has no owning pane. The coordinator mints `ref`/`pane_ref`
/// from the ids so ref minting stays coordinator-side.
public struct ControlBrowserTabRow: Sendable, Equatable {
    /// The browser panel's surface id (`id`, and the source of `ref`).
    public var surfaceID: UUID
    /// The panel's position in the workspace's ordered browser list (`index`).
    public var index: Int
    /// The panel's display title (`title`).
    public var title: String
    /// The panel's current URL absolute string, or `""` (`url`).
    public var url: String
    /// Whether this panel is the workspace's focused panel (`focused`).
    public var focused: Bool
    /// The panel's owning pane id (`pane_id`, and the source of `pane_ref`).
    public var paneID: UUID?

    /// Creates a browser-tab row.
    public init(
        surfaceID: UUID,
        index: Int,
        title: String,
        url: String,
        focused: Bool,
        paneID: UUID?
    ) {
        self.surfaceID = surfaceID
        self.index = index
        self.title = title
        self.url = url
        self.focused = focused
        self.paneID = paneID
    }
}

/// The outcome of `browser.tab.new`, the typed twin of the legacy
/// `TerminalController.v2BrowserTabNew(params:)` body.
///
/// When the cmux browser is disabled, the legacy body forwarded to
/// `v2BrowserDisabledExternalOpenResult`, whose four outcomes are reproduced here
/// (`disabledExternalInvalidURL` / `disabledExternalNoURL` /
/// `disabledExternalOpenFailed` / `disabledExternalOpened`), byte-identical to
/// the `browser.open_split` disabled-fallback shapes.
public enum ControlBrowserTabNewResolution: Sendable, Equatable {
    /// `v2ResolveTabManager` returned nil
    /// (`unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// Browser disabled, the supplied raw URL did not parse
    /// (`invalid_params` / "Invalid URL", data `{"url": <raw>}`).
    case disabledExternalInvalidURL(rawURL: String)
    /// Browser disabled, no URL to open externally
    /// (`browser_disabled` / "cmux browser is disabled").
    case disabledExternalNoURL
    /// Browser disabled, opening the URL externally failed
    /// (`external_open_failed` / "Failed to open URL externally",
    /// data `{"url": <absolute>}`).
    case disabledExternalOpenFailed(url: String)
    /// Browser disabled, the URL was opened externally
    /// (the disabled-fallback success payload, identical to
    /// `browser.open_split`).
    case disabledExternalOpened(windowID: UUID?, url: String)
    /// `v2ResolveWorkspace` returned nil
    /// (`not_found` / "Workspace not found").
    case workspaceNotFound
    /// No target pane could be resolved
    /// (`not_found` / "Target pane not found").
    case paneNotFound
    /// Surface creation failed
    /// (`internal_error` / "Failed to create browser tab").
    case createFailed
    /// Resolved: the owning workspace, the target pane, the created browser
    /// surface, and its current URL absolute string (or `""`).
    case resolved(workspaceID: UUID, paneID: UUID, surfaceID: UUID, url: String)
}

/// The outcome of `browser.tab.switch`, the typed twin of the legacy
/// `TerminalController.v2BrowserTabSwitch(params:)` body.
///
/// The witness reproduces the `v2ResolveTabManager` → `v2ResolveWorkspace` head,
/// resolves the target browser surface (explicit `target_surface_id`/`tab_id`,
/// then `index`, then `surface_id`), and focuses it; the coordinator shapes the
/// identity payload.
public enum ControlBrowserTabSwitchResolution: Sendable, Equatable {
    /// `v2ResolveTabManager` returned nil
    /// (`unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// `v2ResolveWorkspace` returned nil, or no target browser tab resolved
    /// (`not_found` / "Workspace not found" / "Browser tab not found").
    case workspaceNotFound
    /// No matching browser tab (`not_found` / "Browser tab not found").
    case browserTabNotFound
    /// Resolved: the owning workspace and the focused target surface.
    case resolved(workspaceID: UUID, surfaceID: UUID)
}

/// The outcome of `browser.tab.close`, the typed twin of the legacy
/// `TerminalController.v2BrowserTabClose(params:)` body.
///
/// The witness reproduces the `v2ResolveTabManager` → `v2ResolveWorkspace` head,
/// resolves the target browser surface (explicit `target_surface_id`/`tab_id`,
/// then `index`, then `surface_id`, then the focused panel), enforces the
/// last-surface guard, and closes it recording history; the coordinator shapes
/// the identity payload.
public enum ControlBrowserTabCloseResolution: Sendable, Equatable {
    /// `v2ResolveTabManager` returned nil
    /// (`unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// `v2ResolveWorkspace` returned nil
    /// (`not_found` / "Workspace not found").
    case workspaceNotFound
    /// The workspace had no browser tabs (`not_found` / "No browser tabs").
    case noBrowserTabs
    /// No matching browser tab (`not_found` / "Browser tab not found").
    case browserTabNotFound
    /// The workspace had a single surface (`invalid_state` / "Cannot close the
    /// last surface").
    case cannotCloseLastSurface
    /// Closing the surface failed (`internal_error` / "Failed to close browser
    /// tab", data `{"surface_id": <target>}`).
    case closeFailed(surfaceID: UUID)
    /// Resolved: the owning workspace and the closed target surface.
    case resolved(workspaceID: UUID, surfaceID: UUID)
}
