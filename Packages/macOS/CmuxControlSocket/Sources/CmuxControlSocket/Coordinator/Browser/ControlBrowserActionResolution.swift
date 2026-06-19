public import Foundation

/// The outcome of a focused-browser action (`browser.react_grab.toggle` /
/// `browser.devtools.toggle` / `browser.console.show` / `browser.focus_mode.set`
/// / `browser.zoom.set`): either the action ran on a resolved browser surface
/// (carrying the identity payload fields the legacy `v2BrowserActionPayload`
/// built) or no browser surface resolved.
public enum ControlBrowserActionResolution: Sendable, Equatable {
    /// No browser surface resolved (the legacy `.err(not_found, …)` default
    /// each body seeds before its `v2MainSync` block; the exact message differs
    /// per command, so the coordinator supplies it).
    case noBrowserSurface

    /// The action ran. Carries the resolved identity plus the command's
    /// per-action boolean (`handled` / `toggled`) so the coordinator can attach
    /// the matching extra key.
    case acted(ControlBrowserActedSurface)
}

/// The resolved-surface identity of a focused-browser action, the typed twin of
/// the legacy `v2BrowserActionPayload(workspace:surfaceId:tabManager:)` output.
public struct ControlBrowserActedSurface: Sendable, Equatable {
    /// The acted workspace (`workspace_id`).
    public var workspaceID: UUID
    /// The acted browser surface (`surface_id`).
    public var surfaceID: UUID
    /// The owning window (`window_id`), if resolved.
    public var windowID: UUID?
    /// The command-specific result flag (React Grab's `toggled`, the others'
    /// `handled`).
    public var flag: Bool

    /// Creates an acted-surface identity.
    public init(workspaceID: UUID, surfaceID: UUID, windowID: UUID?, flag: Bool) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.windowID = windowID
        self.flag = flag
    }
}
