public import AppKit
public import Foundation

/// Resolves the terminal-surface focus questions the main-window focus controller
/// needs but that depend on app-target terminal infrastructure: which terminal
/// surface owns a first responder, and whether a surface id is a right-sidebar
/// dock surface.
///
/// The app-side conformer bridges these to `cmuxOwningGhosttyView(for:)` (the
/// responder -> owning Ghostty view walk, reading the view's tab and surface ids)
/// and to the terminal surface registry's dock-surface classification. The
/// controller holds the conformer through this seam so it no longer references the
/// concrete Ghostty view type or the app-target registry singleton directly.
@MainActor
public protocol TerminalSurfaceFocusResolving: AnyObject {
    /// The terminal surface that owns `responder`, or `nil` when `responder` is
    /// not hosted by a terminal surface (no owning Ghostty view, or the view has
    /// no tab/surface id).
    ///
    /// Right-sidebar dock surfaces are NOT filtered out here; the caller applies
    /// `isRightSidebarDockSurface(id:)` to the returned `panelId` when it needs to
    /// exclude them.
    func owningTerminalSurfaceFocus(for responder: NSResponder?) -> TerminalSurfaceFocusOwner?

    /// Whether the surface identified by `id` is a right-sidebar dock surface.
    func isRightSidebarDockSurface(id: UUID) -> Bool
}
