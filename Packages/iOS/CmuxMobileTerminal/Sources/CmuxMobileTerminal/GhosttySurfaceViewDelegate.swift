#if canImport(UIKit)
import CMUXMobileCore
import Foundation

/// Host-side sink for everything a ``GhosttySurfaceView`` produces: input
/// bytes for the PTY, natural-grid viewport reports, forwarded gestures, and
/// composer/toolbar requests. The production conformer is the shell layer's
/// surface coordinator; harnesses and tests provide scripted conformers.
@MainActor
public protocol GhosttySurfaceViewDelegate: AnyObject {
    /// Bytes the phone wants to send TO the PTY (typing, paste, mouse
    /// reports). The host forwards them to the Mac, which writes them into
    /// its libghostty surface and down the shared PTY.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data)
    /// The surface's natural grid changed (keyboard, rotation, zoom settle).
    /// `reportID` is a monotonically increasing stamp for THIS report; a host
    /// that round-trips the report to the Mac must hand the same ID back to
    /// `applyConfirmedViewSize(cols:rows:reportID:)` so an echo that resolves
    /// after a newer report was emitted is recognized as stale and dropped
    /// instead of re-pinning the grid the surface already outgrew.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64)
    /// Forward a scroll gesture to the Mac's real surface. `lines` is signed
    /// (sign = direction), `col`/`row` is the grid cell under the finger (so
    /// alt-screen mouse-wheel reports at the right cell). Optional.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didScrollLines lines: Double, atCol col: Int, row: Int)
    /// Forward a tap to the Mac's real surface as a left click at the given grid
    /// cell, so TUIs with mouse reporting (lazygit/htop/fzf) receive the click.
    /// The Mac's libghostty self-gates: a normal screen treats it as a harmless
    /// empty selection. Optional.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didTapAtCol col: Int, row: Int)
    /// The user tapped the "customize" button at the end of the input-accessory
    /// bar; the host should present the toolbar shortcuts editor. Optional.
    func ghosttySurfaceViewDidRequestToolbarSettings(_ surfaceView: GhosttySurfaceView)
    /// Forward an image the user pasted from the system clipboard. The host
    /// uploads `data` to the Mac, which materializes a temp file and injects its
    /// path into the terminal so a running TUI (e.g. Claude Code) attaches it.
    /// `format` is a lowercase file-extension hint (e.g. `"png"`). Optional.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didPasteImage data: Data, format: String)
    /// The composer accessory button was tapped; the host should toggle the
    /// iMessage-style composer above the terminal. Optional.
    ///
    /// The composer is dismissed ONLY by its own chevron or this toggle. The
    /// keyboard collapsing does not dismiss the composer (it survives a keyboard-down
    /// and the toolbar stays visible), so there is no separate collapse/dismiss
    /// delegate hook.
    func ghosttySurfaceViewDidRequestComposerToggle(_ surfaceView: GhosttySurfaceView)
    /// The surface needs the iMessage-style composer presented (if it is not already)
    /// and its field re-focused, without dismissing it. The host ensures the composer
    /// is presented and bumps the focus token the composer view observes. Used on the
    /// reveal-after-hide and the present-while-suppressed paths so the draft and its
    /// focus return together. Optional.
    func ghosttySurfaceViewDidRequestComposerFocus(_ surfaceView: GhosttySurfaceView)
    /// The local Ghostty render pipeline was rebuilt after a stuck render/output
    /// operation. The host should replay authoritative terminal state.
    func ghosttySurfaceViewDidResetRenderPipeline(_ surfaceView: GhosttySurfaceView)
}

/// Default no-op implementations for the optional delegate requirements, so
/// hosts only implement the surfaces they actually route.
public extension GhosttySurfaceViewDelegate {
    /// Default no-op so hosts without remote scroll forwarding can ignore it.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didScrollLines lines: Double, atCol col: Int, row: Int) {}
    /// Default no-op so hosts without remote click forwarding can ignore it.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didTapAtCol col: Int, row: Int) {}
    /// Default no-op so hosts without a toolbar editor can ignore the request.
    func ghosttySurfaceViewDidRequestToolbarSettings(_ surfaceView: GhosttySurfaceView) {}
    /// Default no-op so hosts without image upload can ignore pasted images.
    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didPasteImage data: Data, format: String) {}
    /// Default no-op so hosts without a composer can ignore the toggle request.
    func ghosttySurfaceViewDidRequestComposerToggle(_ surfaceView: GhosttySurfaceView) {}
    /// Default no-op so hosts without a composer can ignore the focus request.
    func ghosttySurfaceViewDidRequestComposerFocus(_ surfaceView: GhosttySurfaceView) {}
    /// Default no-op so hosts without terminal-output replay can ignore renderer resets.
    func ghosttySurfaceViewDidResetRenderPipeline(_ surfaceView: GhosttySurfaceView) {}
}
#endif
