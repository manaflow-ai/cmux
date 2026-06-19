public import Foundation

/// The outcome of `browser.open_split`, preserving each legacy `v2BrowserOpenSplit`
/// return shape exactly (every error code/message/data and every success payload
/// field). The coordinator shapes the matching ``ControlCallResult`` /
/// ``JSONValue`` payload from this value.
public enum ControlBrowserOpenSplitResolution: Sendable, Equatable {
    /// The routed `TabManager` did not resolve
    /// (`unavailable` / "TabManager not available").
    case tabManagerUnavailable

    /// The `url` param resolved to neither a navigable URL nor a search query
    /// (`invalid_params` / "Could not resolve URL or search query", data
    /// `{"url": <raw>}`).
    case unresolvableURL(rawURL: String)

    /// The cmux browser is disabled and the target is a diff-viewer URL
    /// (`browser_disabled` / "cmux browser is disabled").
    case browserDisabled

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
    /// (the disabled-fallback success payload).
    case disabledExternalOpened(windowID: UUID?, url: String)

    /// The trusted diff-viewer allowlist was missing or invalid
    /// (`invalid_params` / "Missing or invalid trusted diff viewer allowlist",
    /// or "Invalid trusted diff viewer allowlist" with optional `details`).
    case invalidDiffViewerAllowlist(message: String, details: String?)

    /// The workspace did not resolve (`not_found` / "Workspace not found").
    case workspaceNotFound

    /// `respect_external_open_rules` applied and the external open failed
    /// (`external_open_failed` / "Failed to open URL externally",
    /// data `{"url": <absolute>}`).
    case externalOpenRespectedFailed(url: String)

    /// `respect_external_open_rules` applied and the URL opened externally
    /// (the external-respected success payload).
    case externalOpenRespected(windowID: UUID?, workspaceID: UUID, url: String)

    /// No focused surface to split off (`not_found` / "No focused surface to
    /// split").
    case noFocusedSurface

    /// The explicit source surface was not found in the workspace
    /// (`not_found` / "Source surface not found", data `{"surface_id": …}`).
    case sourceSurfaceNotFound(surfaceID: UUID)

    /// Split creation failed (`internal_error` / "Failed to create browser").
    case createFailed

    /// A browser split (or reuse) was created. Carries every identity field the
    /// legacy success payload reported.
    case created(ControlBrowserOpenSplitSuccess)
}

/// The success payload of `browser.open_split`: the full identity tree of the
/// created browser plus its placement metadata.
public struct ControlBrowserOpenSplitSuccess: Sendable, Equatable {
    /// The created browser surface id (`surface_id`).
    public var browserSurfaceID: UUID
    /// The source surface the split came off (`source_surface_id`).
    public var sourceSurfaceID: UUID
    /// The source surface's pane (`source_pane_id`), if any.
    public var sourcePaneID: UUID?
    /// The created browser's pane (`pane_id` / `target_pane_id`), if any.
    public var targetPaneID: UUID?
    /// The owning workspace (`workspace_id`).
    public var workspaceID: UUID
    /// The owning window (`window_id`), if resolved.
    public var windowID: UUID?
    /// Whether a brand-new split was created vs a right sibling reused
    /// (`created_split`).
    public var createdSplit: Bool
    /// The placement strategy string (`placement_strategy`).
    public var placementStrategy: String
    /// Whether the new browser's omnibar is visible (`show_omnibar`).
    public var omnibarVisible: Bool
    /// Whether the new browser uses a transparent background
    /// (`transparent_background`).
    public var transparentBackground: Bool
    /// Whether the new browser bypasses the remote proxy (`bypass_remote_proxy`).
    public var bypassRemoteProxy: Bool

    /// Creates a success payload.
    public init(
        browserSurfaceID: UUID,
        sourceSurfaceID: UUID,
        sourcePaneID: UUID?,
        targetPaneID: UUID?,
        workspaceID: UUID,
        windowID: UUID?,
        createdSplit: Bool,
        placementStrategy: String,
        omnibarVisible: Bool,
        transparentBackground: Bool,
        bypassRemoteProxy: Bool
    ) {
        self.browserSurfaceID = browserSurfaceID
        self.sourceSurfaceID = sourceSurfaceID
        self.sourcePaneID = sourcePaneID
        self.targetPaneID = targetPaneID
        self.workspaceID = workspaceID
        self.windowID = windowID
        self.createdSplit = createdSplit
        self.placementStrategy = placementStrategy
        self.omnibarVisible = omnibarVisible
        self.transparentBackground = transparentBackground
        self.bypassRemoteProxy = bypassRemoteProxy
    }
}
