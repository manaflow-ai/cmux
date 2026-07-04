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
/// resolves to no target); then group, workstream, workspace, surface, pane,
/// caller's own window, then the active scriptable window.
public struct ControlRoutingSelectors: Sendable, Equatable {
    /// Whether the request carried a non-null `window_id` param at all. A
    /// present-but-unresolvable `window_id` must resolve to no target rather
    /// than falling through to the other selectors (legacy behavior).
    public let hasWindowIDParam: Bool
    /// The resolved `window_id` target, if the param parsed to a known window.
    public let windowID: UUID?
    /// The resolved `group_id` target, if any.
    public let groupID: UUID?
    /// The resolved `workstream_id` target, if any.
    public let workstreamID: UUID?
    /// The resolved `workspace_id` target, if any.
    public let workspaceID: UUID?
    /// The resolved surface target (`surface_id`, then `terminal_id`, then
    /// `tab_id`), if any.
    public let surfaceID: UUID?
    /// The resolved `pane_id` target, if any.
    public let paneID: UUID?

    /// Creates a routing-selectors value.
    ///
    /// - Parameters:
    ///   - hasWindowIDParam: Whether a non-null `window_id` param was present.
    ///   - windowID: The resolved `window_id` target.
    ///   - groupID: The resolved `group_id` target.
    ///   - workstreamID: The resolved `workstream_id` target.
    ///   - workspaceID: The resolved `workspace_id` target.
    ///   - surfaceID: The resolved surface target.
    ///   - paneID: The resolved `pane_id` target.
    public init(
        hasWindowIDParam: Bool,
        windowID: UUID?,
        groupID: UUID?,
        workstreamID: UUID?,
        workspaceID: UUID?,
        surfaceID: UUID?,
        paneID: UUID?
    ) {
        self.hasWindowIDParam = hasWindowIDParam
        self.windowID = windowID
        self.groupID = groupID
        self.workstreamID = workstreamID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.paneID = paneID
    }
}
