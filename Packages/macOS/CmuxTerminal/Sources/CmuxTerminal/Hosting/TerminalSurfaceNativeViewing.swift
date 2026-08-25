public import AppKit
public import CmuxTerminalCore
public import Foundation
public import GhosttyKit

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

    /// Ends keyboard copy mode and clears its selection when focus leaves the view.
    func cancelKeyboardCopyMode()

    /// Re-applies the window background for the active surface.
    func applyWindowBackgroundIfActive()

    /// Forces a synchronous surface size/draw refresh.
    ///
    /// - Returns: Whether a refresh was performed.
    @discardableResult
    func forceRefreshSurface() -> Bool

    /// Resets view-owned state and accepts callbacks for the native surface
    /// lifetime that is about to be created.
    /// - Parameter runtimeLifetimeId: The callback-context identity installed
    ///   before the native constructor can emit actions.
    /// - Returns: The ingress generation assigned to this runtime lifetime.
    @discardableResult
    func prepareForRuntimeSurfaceCreation(runtimeLifetimeId: UUID) -> UInt64

    /// Resets view-owned state and rejects callbacks from an ended native
    /// surface lifetime.
    ///
    /// - Parameter runtimeLifetimeId: The ended callback-context identity, or
    ///   `nil` when replacing the entire surface owner unconditionally.
    func runtimeSurfaceDidEnd(runtimeLifetimeId: UUID?)

    /// Reconciles view-owned state after a new native Ghostty surface lifetime
    /// is installed.
    func runtimeSurfaceDidBecomeReady()

    /// Defers programmatic runtime input behind an active clipboard read.
    ///
    /// - Parameters:
    ///   - estimatedBytes: Approximate retained payload size for queue bounds.
    ///   - replay: The input mutation to retry after the clipboard read ends.
    /// - Returns: Whether the input was accepted for deferred replay.
    @discardableResult
    func deferRuntimeInputDuringClipboardRead(
        estimatedBytes: Int,
        replay: @escaping () -> Void
    ) -> Bool

    /// Positions the native pointer at the center of a mobile-selected cell.
    func positionMobilePointer(
        on surface: ghostty_surface_t,
        column: Int,
        row: Int,
        contentScale: CGFloat
    )

    /// Sends one mobile mouse-button edge to the native surface.
    func sendMobileMouseButton(
        _ state: ghostty_input_mouse_state_e,
        on surface: ghostty_surface_t
    )
}

public extension TerminalSurfaceNativeViewing {
    /// Leaves input synchronous for hosts without clipboard sequencing.
    ///
    /// - Parameters:
    ///   - estimatedBytes: Approximate retained payload size; unused by the
    ///     synchronous default.
    ///   - replay: The input mutation; unused because the caller continues
    ///     synchronously when this method returns `false`.
    /// - Returns: Always `false`.
    @discardableResult
    func deferRuntimeInputDuringClipboardRead(
        estimatedBytes _: Int,
        replay _: @escaping () -> Void
    ) -> Bool {
        false
    }

    /// Uses Ghostty's point-space pointer API for the selected grid cell.
    func positionMobilePointer(
        on surface: ghostty_surface_t,
        column: Int,
        row: Int,
        contentScale: CGFloat
    ) {
        let size = ghostty_surface_size(surface)
        let scale = max(Double(contentScale), 1)
        let cellWidth = Double(size.cell_width_px) / scale
        let cellHeight = Double(size.cell_height_px) / scale
        ghostty_surface_mouse_pos(
            surface,
            (Double(max(0, column)) + 0.5) * cellWidth,
            (Double(max(0, row)) + 0.5) * cellHeight,
            GHOSTTY_MODS_NONE
        )
    }

    /// Sends one left-button edge through Ghostty.
    func sendMobileMouseButton(
        _ state: ghostty_input_mouse_state_e,
        on surface: ghostty_surface_t
    ) {
        _ = ghostty_surface_mouse_button(
            surface,
            state,
            GHOSTTY_MOUSE_LEFT,
            GHOSTTY_MODS_NONE
        )
    }
}
