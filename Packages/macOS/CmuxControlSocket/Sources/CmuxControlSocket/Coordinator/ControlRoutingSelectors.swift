public import Foundation

/// The pre-resolved routing selectors a control command carries to pick the
/// window/workspace it targets.
///
/// ``ControlCommandCoordinator`` parses these from the request params (resolving
/// `kind:N` refs through its handle registry, exactly as the legacy `v2UUID`
/// did) and hands them to ``ControlCommandContext`` so the app target can run
/// the same precedence walk the former `v2ResolveTabManager` used, without the
/// package importing `TabManager`.
///
/// Precedence (highest first), preserved from the legacy resolver: an explicit
/// `window_id` param wins outright (and a present-but-unresolvable `window_id`
/// resolves to no target); then group, then workspace, then surface, then pane;
/// finally the caller's own window, then the active scriptable window.
public struct ControlRoutingSelectors: Sendable, Equatable {
    /// Whether the request carried a non-null `window_id` param at all. A
    /// present-but-unresolvable `window_id` must resolve to no target rather
    /// than falling through to the other selectors (legacy behavior).
    public let hasWindowIDParam: Bool
    /// The resolved `window_id` target, if the param parsed to a known window.
    public let windowID: UUID?
    /// The resolved `group_id` target, if any.
    public let groupID: UUID?
    /// Whether the request carried a non-null `group_id` param. This stays true
    /// when parsing or handle resolution fails so routing can fail closed.
    public let hasGroupIDParam: Bool
    /// The resolved `workspace_id` target, if any.
    public let workspaceID: UUID?
    /// Whether the request carried a non-null `workspace_id` param. This stays
    /// true when parsing or handle resolution fails so app routing can fail
    /// closed instead of treating the selector as omitted.
    public let hasWorkspaceIDParam: Bool
    /// The resolved surface target (`surface_id`, then `terminal_id`, then
    /// `tab_id`), if any.
    public let surfaceID: UUID?
    /// Whether the request carried any non-null surface selector.
    public let hasSurfaceIDParam: Bool
    /// The resolved `pane_id` target, if any.
    public let paneID: UUID?
    /// Whether the request carried a non-null `pane_id` param.
    public let hasPaneIDParam: Bool

    /// Creates a routing-selectors value.
    ///
    /// - Parameters:
    ///   - hasWindowIDParam: Whether a non-null `window_id` param was present.
    ///   - windowID: The resolved `window_id` target.
    ///   - groupID: The resolved `group_id` target.
    ///   - workspaceID: The resolved `workspace_id` target.
    ///   - surfaceID: The resolved surface target.
    ///   - paneID: The resolved `pane_id` target.
    ///   - hasGroupIDParam: Whether a non-null group selector was present.
    ///     Defaults to whether `groupID` is non-nil.
    ///   - hasWorkspaceIDParam: Whether a non-null workspace selector was
    ///     present. Defaults to whether `workspaceID` is non-nil.
    ///   - hasSurfaceIDParam: Whether a non-null surface selector was present.
    ///     Defaults to whether `surfaceID` is non-nil.
    ///   - hasPaneIDParam: Whether a non-null pane selector was present.
    ///     Defaults to whether `paneID` is non-nil.
    public init(
        hasWindowIDParam: Bool,
        windowID: UUID?,
        groupID: UUID?,
        workspaceID: UUID?,
        surfaceID: UUID?,
        paneID: UUID?,
        hasGroupIDParam: Bool? = nil,
        hasWorkspaceIDParam: Bool? = nil,
        hasSurfaceIDParam: Bool? = nil,
        hasPaneIDParam: Bool? = nil
    ) {
        self.hasWindowIDParam = hasWindowIDParam
        self.windowID = windowID
        self.groupID = groupID
        self.hasGroupIDParam = hasGroupIDParam ?? (groupID != nil)
        self.workspaceID = workspaceID
        self.hasWorkspaceIDParam = hasWorkspaceIDParam ?? (workspaceID != nil)
        self.surfaceID = surfaceID
        self.hasSurfaceIDParam = hasSurfaceIDParam ?? (surfaceID != nil)
        self.paneID = paneID
        self.hasPaneIDParam = hasPaneIDParam ?? (paneID != nil)
    }
}
