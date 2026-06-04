public import Foundation

/// The per-surface libghostty operations a ``GhosttySurfaceSession`` owns.
///
/// The production conformance (``GhosttyKitSurfaceBackend``) wraps one
/// `ghostty_surface_t`; tests inject a scripted fake to verify the session's
/// ordering, coalescing, and disposal behavior without linking a live
/// terminal. Methods marked *blocking* can park the calling thread on
/// libghostty's internal renderer/IO synchronization — the session only ever
/// invokes them on its dedicated serial executor, never the main thread
/// (running them on main is what tripped the 0x8BADF00D scene-update
/// watchdog).
public protocol GhosttySurfaceControlling: Sendable {
    /// Feeds PTY bytes into the terminal. **Blocking.**
    func processOutput(_ data: Data)
    /// Runs a full synchronous render pass. **Blocking.**
    func renderNow()
    /// Performs a keybinding action string (e.g. `set_font_size:12`).
    /// **Blocking** (mailbox push).
    func performBindingAction(_ action: String)
    /// Sends committed text through the key-input path. **Blocking.**
    func sendTextInput(_ text: String)
    /// Sends text through the paste path. **Blocking.**
    func sendPasteText(_ text: String)
    /// Requests a surface size in pixels. **Blocking** (mailbox push).
    func setSize(pixelWidth: UInt32, pixelHeight: UInt32)
    /// Pushes a new content scale. **Blocking** (mailbox push).
    func setContentScale(_ x: Double, _ y: Double)
    /// Reads back the current measured grid.
    func measuredSize() -> GhosttySurfaceMeasuredSize
    /// Reads the surface text for one scope, or `nil` when unavailable.
    func readText(_ scope: GhosttySurfaceTextScope) -> String?
    /// Whether the surface's child process has exited.
    func processExited() -> Bool
    /// Sets keyboard focus state. Cheap push; safe from the main thread
    /// (matches the pre-actor behavior).
    func setFocus(_ focused: Bool)
    /// Sets occlusion state (`visible == false` skips draws). Cheap push;
    /// safe from the main thread (matches the pre-actor behavior).
    func setOcclusion(visible: Bool)
    /// Reads the IME caret point (used for the cursor overlay). Cheap read;
    /// safe from the main thread (matches the pre-actor behavior).
    func imePoint() -> GhosttySurfaceIMEPoint
    /// Frees the surface. Called exactly once, after all queued work drained.
    func free()
}
