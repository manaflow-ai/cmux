#if canImport(GhosttyKit)
internal import GhosttyKit
import Foundation

/// The production ``GhosttySurfaceControlling`` over one `ghostty_surface_t`.
///
/// A reference type on purpose: it owns the surface handle and the retained
/// callback bridge, so copyable-value semantics could duplicate ownership and
/// double-free.
///
/// `@unchecked Sendable` justification: `surface` is an opaque C handle whose
/// blocking operations are only ever invoked on the owning session's dedicated
/// serial executor (plus the three documented cheap main-thread calls, which
/// libghostty itself synchronizes); the handle is freed exactly once by the
/// session after its command stream drains.
final class GhosttyKitSurfaceBackend: GhosttySurfaceControlling, @unchecked Sendable {
    let surface: ghostty_surface_t
    /// The retained C-callback bridge released together with the surface so
    /// in-flight `io_write` callbacks never dangle (the pre-actor
    /// `GhosttySurfaceDisposer` retain dance).
    private let retainedBridge: Unmanaged<GhosttySurfaceCallbackBridge>

    init(surface: ghostty_surface_t, bridge: GhosttySurfaceCallbackBridge) {
        self.surface = surface
        retainedBridge = Unmanaged.passRetained(bridge)
    }

    func processOutput(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let pointer = baseAddress.assumingMemoryBound(to: CChar.self)
            ghostty_surface_process_output(surface, pointer, UInt(buffer.count))
        }
    }

    func renderNow() {
        ghostty_surface_render_now(surface)
    }

    func performBindingAction(_ action: String) {
        action.withCString { pointer in
            _ = ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }
    }

    func sendTextInput(_ text: String) {
        let count = text.utf8CString.count
        guard count > 1 else { return }
        text.withCString { pointer in
            ghostty_surface_text_input(surface, pointer, UInt(count - 1))
        }
    }

    func sendPasteText(_ text: String) {
        let count = text.utf8CString.count
        guard count > 1 else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(count - 1))
        }
    }

    func setSize(pixelWidth: UInt32, pixelHeight: UInt32) {
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
    }

    func setContentScale(_ x: Double, _ y: Double) {
        ghostty_surface_set_content_scale(surface, x, y)
    }

    func measuredSize() -> GhosttySurfaceMeasuredSize {
        let size = ghostty_surface_size(surface)
        return GhosttySurfaceMeasuredSize(
            columns: Int(size.columns),
            rows: Int(size.rows),
            pixelWidth: Int(size.width_px),
            pixelHeight: Int(size.height_px)
        )
    }

    func readText(_ scope: GhosttySurfaceTextScope) -> String? {
        let tag: ghostty_point_tag_e
        switch scope {
        case .viewport: tag = GHOSTTY_POINT_VIEWPORT
        case .screen: tag = GHOSTTY_POINT_SCREEN
        case .active: tag = GHOSTTY_POINT_ACTIVE
        case .surface: tag = GHOSTTY_POINT_SURFACE
        }
        let topLeft = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        let bottomRight = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        let selection = ghostty_selection_s(top_left: topLeft, bottom_right: bottomRight, rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: Data(bytes: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    func processExited() -> Bool {
        ghostty_surface_process_exited(surface)
    }

    func setFocus(_ focused: Bool) {
        ghostty_surface_set_focus(surface, focused)
    }

    func setOcclusion(visible: Bool) {
        ghostty_surface_set_occlusion(surface, visible)
    }

    func imePoint() -> GhosttySurfaceIMEPoint {
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        return GhosttySurfaceIMEPoint(x: x, y: y, width: width, height: height)
    }

    func completeClipboardRequest(text: String, stateBits: Int) {
        let statePointer = stateBits == 0 ? nil : UnsafeMutableRawPointer(bitPattern: stateBits)
        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, statePointer, false)
        }
    }

    func free() {
        ghostty_surface_free(surface)
        retainedBridge.release()
    }
}
#endif
