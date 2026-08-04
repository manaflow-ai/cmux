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
    /// The resolved `workspace_id` target, if any.
    public let workspaceID: UUID?
    /// The resolved surface target (`surface_id`, then `terminal_id`, then
    /// `tab_id`), if any.
    public let surfaceID: UUID?
    /// The resolved `pane_id` target, if any.
    public let paneID: UUID?
    /// Whether any routing selector was supplied but could not be resolved —
    /// a wrong-kind ref or id, an unknown `kind:N` ref, or a blank/non-string
    /// value.
    ///
    /// A supplied-but-invalid selector is NOT the same as an absent one: a
    /// `nil` id alone reads as "caller did not target this", so the walk would
    /// slide past it to the active window and run the command against an
    /// implicit target the caller never named
    /// (https://github.com/manaflow-ai/cmux/issues/9424). The walk must fail
    /// closed when this is set, exactly as it already does for a
    /// present-but-unresolvable `window_id`.
    ///
    /// This deliberately does not cover a well-formed id that names nothing
    /// live: that is the issue's gap 1, where the CLI's injected caller
    /// context is indistinguishable on the wire from a user-specified target.
    public let hasRejectedSelector: Bool

    /// Creates a routing-selectors value.
    ///
    /// - Parameters:
    ///   - hasWindowIDParam: Whether a non-null `window_id` param was present.
    ///   - windowID: The resolved `window_id` target.
    ///   - groupID: The resolved `group_id` target.
    ///   - workspaceID: The resolved `workspace_id` target.
    ///   - surfaceID: The resolved surface target.
    ///   - paneID: The resolved `pane_id` target.
    ///   - hasRejectedSelector: Whether a supplied selector failed to resolve.
    public init(
        hasWindowIDParam: Bool,
        windowID: UUID?,
        groupID: UUID?,
        workspaceID: UUID?,
        surfaceID: UUID?,
        paneID: UUID?,
        hasRejectedSelector: Bool = false
    ) {
        self.hasWindowIDParam = hasWindowIDParam
        self.windowID = windowID
        self.groupID = groupID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.paneID = paneID
        self.hasRejectedSelector = hasRejectedSelector
    }
}
