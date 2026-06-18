public import AppKit
public import CmuxTerminalCore

/// The inner terminal NSView a ``TerminalSurface`` renders into.
///
/// The concrete view (`GhosttyNSView`) lives above this package in the view
/// layer; the surface model drives it exclusively through this seam plus the
/// `NSView` superclass surface (bounds, window, layer, backing conversions).
/// The protocol also refines `TerminalSurfaceHosting` because the ghostty
/// callback context identifies its host view through that core seam.
@MainActor
public protocol TerminalSurfaceNativeViewing: NSView, TerminalSurfaceHosting {
    /// The owning workspace id mirrored onto the view for focus routing.
    var tabId: UUID? { get set }

    /// The key-state indicator text currently shown for this view
    /// (copy-mode/key-table), or nil when no indicator applies.
    var currentKeyStateIndicatorText: String? { get }

    /// Whether keyboard copy mode is active on this view.
    var isKeyboardCopyModeActive: Bool { get }

    /// Toggles keyboard copy mode.
    ///
    /// - Returns: Whether the view handled the toggle.
    @discardableResult
    func toggleKeyboardCopyMode() -> Bool

    /// Re-applies the window background for the active surface.
    func applyWindowBackgroundIfActive()

    /// Forces a synchronous surface size/draw refresh.
    ///
    /// - Returns: Whether a refresh was performed.
    @discardableResult
    func forceRefreshSurface() -> Bool
}
