public import Foundation

/// The outcome of `surface.action` / `tab.action` (the legacy `v2TabAction`
/// body). The app runs the resolution + mutation in the legacy order; the
/// coordinator maps each case onto the exact legacy result.
public enum ControlTabActionResolution: Sendable, Equatable {
    /// The per-action success extras of the `finish(_:)` payload.
    public enum Extras: Sendable, Equatable {
        /// No extra keys.
        case none
        /// `rename` — the resulting `title`.
        case title(String)
        /// `pin` / `unpin` — the `pinned` flag.
        case pinned(Bool)
        /// `duplicate` / `new_terminal_right` / `new_browser_right` — the
        /// created surface's `created_*` identity keys.
        case created(UUID)
        /// `new_terminal_right` on a remote tmux mirror — the create was
        /// routed to the remote as `new-window`; the tab arrives via
        /// `%window-add`, so the `created_*` keys are null and the payload
        /// carries `accepted` / `routed` instead.
        case routedToRemote
        /// `close_left` / `close_right` / `close_others` — the `closed` and
        /// `skipped_pinned` counts.
        case closed(closed: Int, skippedPinned: Int)
    }

    /// The success identity + extras of the legacy `finish(_:)` payload.
    public struct Outcome: Sendable, Equatable {
        /// The enclosing workspace.
        public let workspaceID: UUID
        /// The acted-on surface.
        public let surfaceID: UUID
        /// The routed window, if it resolved.
        public let windowID: UUID?
        /// The surface's enclosing pane at finish time, if it resolved.
        public let paneID: UUID?
        /// The per-action extras.
        public let extras: Extras

        /// Creates an action outcome.
        ///
        /// - Parameters:
        ///   - workspaceID: The enclosing workspace.
        ///   - surfaceID: The acted-on surface.
        ///   - windowID: The routed window, if any.
        ///   - paneID: The enclosing pane at finish time, if any.
        ///   - extras: The per-action extras.
        public init(
            workspaceID: UUID,
            surfaceID: UUID,
            windowID: UUID?,
            paneID: UUID?,
            extras: Extras
        ) {
            self.workspaceID = workspaceID
            self.surfaceID = surfaceID
            self.windowID = windowID
            self.paneID = paneID
            self.extras = extras
        }
    }

    /// No TabManager resolved for the routing selectors.
    case tabManagerUnavailable
    /// The `action` param was missing.
    case missingAction
    /// The routed workspace was not found.
    case workspaceNotFound
    /// No explicit surface and the workspace has no focused panel.
    case noFocusedTab
    /// The targeted surface is not in the workspace.
    case tabNotFound(surfaceID: UUID)
    /// The action key is not in the supported set.
    case unknownAction
    /// `rename` without a usable `title`.
    case invalidTitle
    /// `new_browser_right` with an unparsable `url`.
    case invalidURL(rawURL: String)
    /// `reload` on a non-browser surface.
    case reloadNotBrowser
    /// `duplicate` on a non-browser surface.
    case duplicateNotBrowser
    /// `open_in_browser` on a non-file-backed surface or a file that should not
    /// route to the embedded browser.
    case openInBrowserNotFile
    /// The cmux browser is disabled; the app already attempted the external
    /// open (shared `v2BrowserDisabledExternalOpenResult` outcome).
    case browserDisabled(ControlSurfaceBrowserDisabledOutcome)
    /// The surface's pane could not be resolved.
    case tabPaneNotFound
    /// The anchor tab was not found in its pane (`close_left` / `close_right`).
    case tabNotFoundInPane
    /// Surface creation failed (`new_terminal_right` / `new_browser_right`).
    case createFailed
    /// Browser duplication failed.
    case duplicateFailed
    /// A fully-shaped result bridged from the still-app-side
    /// move-to-new-workspace family (`move_to_new_workspace` /
    /// `detach_to_workspace` / `detach_to_new_workspace`).
    case bridged(ControlCallResult)
    /// The action ran; emit the legacy `finish(_:)` payload.
    case completed(Outcome)
}
