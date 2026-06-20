public import Foundation

/// The typed outcome of one worker-lane `browser.*` navigation command, returned
/// by the ``ControlBrowserNavigationReading`` seam to
/// ``ControlBrowserNavigationWorker``.
///
/// Each case is the byte-faithful twin of one branch the legacy
/// `TerminalController.v2BrowserNavigate` / `v2BrowserNavSimple` bodies took. The
/// worker shapes each case into the wire payload; the app conformer resolves the
/// `TabManager`, the `surface_id` handle, the workspace and browser panel,
/// performs the navigation, computes the `workspace_ref` / `surface_ref` /
/// `window_ref` strings (which reach the god-owned handle registry, unavailable
/// to this package), and runs the optional post-action snapshot.
public enum ControlBrowserNavigationResolution: Sendable, Equatable {
    /// `v2ResolveTabManager` returned `nil` (the legacy `unavailable` /
    /// "TabManager not available" branch).
    case tabManagerUnavailable

    /// `v2UUID(_:"surface_id")` returned `nil` (the legacy `invalid_params` /
    /// "Missing or invalid surface_id" branch).
    case invalidSurfaceID

    /// `browser.navigate` only: the `url` param was absent (the legacy
    /// `invalid_params` / "Missing url" branch, which the legacy body checked
    /// after `TabManager` and `surface_id` resolution).
    case missingURL

    /// The workspace/browser-panel resolution failed (the legacy `not_found` /
    /// "Surface not found or not a browser" branch). Carries the resolved
    /// `surface_id` the legacy body echoed under the `surface_id` data key.
    case surfaceNotFound(surfaceID: UUID)

    /// The navigation ran. Carries the identity payload fields the legacy bodies
    /// emitted plus the merged post-action snapshot keys
    /// (``ControlBrowserNavigated/postSnapshot``).
    case navigated(ControlBrowserNavigated)
}

/// A completed navigation: the identity the worker needs to shape the success
/// payload, byte-faithful to the fields the legacy bodies emitted.
public struct ControlBrowserNavigated: Sendable, Equatable {
    /// The resolved workspace id (`ws.id`).
    public let workspaceID: UUID
    /// The `workspace_ref` string (`v2Ref(kind: .workspace, …)`), computed
    /// app-side against the god-owned handle registry.
    public let workspaceRef: String
    /// The resolved browser surface id (`surfaceId`).
    public let surfaceID: UUID
    /// The `surface_ref` string (`v2Ref(kind: .surface, …)`).
    public let surfaceRef: String
    /// The resolved window id, or `nil` (`v2ResolveWindowId`), emitted as
    /// `v2OrNull(windowID?.uuidString)`.
    public let windowID: UUID?
    /// The `window_ref` string, or `nil` when there is no window
    /// (`v2Ref(kind: .window, …)` returned `NSNull`).
    public let windowRef: String?
    /// The merged post-action snapshot keys (`post_action_snapshot` /
    /// `post_action_refs` / `post_action_title` / `post_action_url` /
    /// `post_action_snapshot_error`), built app-side by
    /// `v2BrowserAppendPostSnapshot` and bridged to ``JSONValue``. Empty when
    /// `snapshot_after` was not requested.
    public let postSnapshot: [String: JSONValue]

    /// Creates a navigated value.
    public init(
        workspaceID: UUID,
        workspaceRef: String,
        surfaceID: UUID,
        surfaceRef: String,
        windowID: UUID?,
        windowRef: String?,
        postSnapshot: [String: JSONValue]
    ) {
        self.workspaceID = workspaceID
        self.workspaceRef = workspaceRef
        self.surfaceID = surfaceID
        self.surfaceRef = surfaceRef
        self.windowID = windowID
        self.windowRef = windowRef
        self.postSnapshot = postSnapshot
    }
}
