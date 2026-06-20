public import Foundation

/// The typed outcome of a `browser.*` interaction command, returned by the
/// ``ControlBrowserInteractionReading`` seam to ``ControlBrowserInteractionWorker``.
///
/// The interaction commands split into two payload-shaping shapes, preserved here
/// byte-faithfully:
///
/// - The selector-action family (`click`/`dblclick`/`hover`/`focus`/`type`/
///   `fill`/`check`/`uncheck`/`select`/`scroll_into_view`/`highlight`) runs the
///   shared `v2BrowserSelectorAction` retry loop, which is STILL SHARED with the
///   not-yet-extracted `browser.get.*` / `browser.is.*` query commands and so
///   stays app-side. That body builds its entire wire payload (the
///   `action`/`attempts`/`value` success shape and the rich not-found
///   diagnostics) app-side, so this resolution carries the already-shaped result
///   verbatim via ``preShaped(_:)``.
/// - The per-panel family (`press`/`keydown`/`keyup`/`scroll`) has a small,
///   self-contained payload (the workspace/surface identity plus the optional
///   `--snapshot-after` walk), which the worker shapes from ``panelAction(_:)``.
///   Their error branches that reuse shared app-side helpers (the not-found
///   diagnostics for a scroll on a missing element, the ref-not-found echo) are
///   likewise carried pre-shaped.
public enum ControlBrowserInteractionResolution: Sendable, Equatable {
    /// The command's full wire result was built app-side and is carried verbatim.
    /// Used for every selector-action command (whose shared retry body owns the
    /// payload), and for the `scroll`/`press`/`keyup`/`keydown` error branches that
    /// reuse shared app-side helpers (`v2BrowserElementNotFoundResult`, the
    /// ref-not-found echo, the panel-resolution failures, and the `js_error`
    /// branch).
    case preShaped(ControlCallResult)

    /// A `press`/`keydown`/`keyup`/`scroll` success: the worker shapes the
    /// workspace/surface identity payload and merges the post-action snapshot,
    /// byte-faithful to the legacy bodies.
    case panelAction(ControlBrowserPanelActionSuccess)
}

/// The resolved success identity for a `press`/`keydown`/`keyup`/`scroll`
/// interaction, byte-faithful to the fields the legacy bodies emitted.
public struct ControlBrowserPanelActionSuccess: Sendable, Equatable {
    /// The resolved workspace id (`ctx.workspaceId`).
    public let workspaceID: UUID
    /// The `workspace_ref` string (`v2Ref(kind: .workspace, …)`), computed
    /// app-side against the god-owned handle registry.
    public let workspaceRef: String
    /// The resolved browser surface id (`ctx.surfaceId`).
    public let surfaceID: UUID
    /// The `surface_ref` string (`v2Ref(kind: .surface, …)`).
    public let surfaceRef: String
    /// The `--snapshot-after` walk the legacy body merged into the success payload
    /// (`v2BrowserAppendPostSnapshot`), already typed; empty when `snapshot_after`
    /// was not requested.
    public let postSnapshot: [String: JSONValue]

    /// Creates a panel-action success value.
    public init(
        workspaceID: UUID,
        workspaceRef: String,
        surfaceID: UUID,
        surfaceRef: String,
        postSnapshot: [String: JSONValue]
    ) {
        self.workspaceID = workspaceID
        self.workspaceRef = workspaceRef
        self.surfaceID = surfaceID
        self.surfaceRef = surfaceRef
        self.postSnapshot = postSnapshot
    }
}
