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
    /// The AppKit view whose native handle the active renderer draws into.
    ///
    /// Ghostty uses the conforming view itself. Alternate renderers can supply
    /// a dedicated child view while preserving this view as cmux's responder
    /// and portal host.
    var terminalRenderTargetView: NSView { get }

    /// Receives an OSC title update from the active terminal runtime.
    func terminalRuntimeTitleDidChange(_ title: String)

    /// Receives the local terminal child-process exit code.
    func terminalRuntimeChildDidExit(_ exitCode: Int32)

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

extension TerminalSurfaceNativeViewing {
    /// Uses the terminal surface view itself as the default renderer target.
    public var terminalRenderTargetView: NSView { self }

    /// Ignores title changes when a host does not expose title state.
    public func terminalRuntimeTitleDidChange(_ title: String) {}

    /// Ignores child exit when a host does not expose an exit overlay.
    public func terminalRuntimeChildDidExit(_ exitCode: Int32) {}
}
