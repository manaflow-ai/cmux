internal import Foundation
internal import GhosttyKit

/// A bounded native screen-tail read ordered before later teardown requests.
///
/// The raw surface pointer remains owned by its ``TerminalSurface``. The request
/// carries the matching runtime-generation gate while it waits for global read
/// admission. The reader must acquire that gate before dereferencing the pointer;
/// a teardown that wins first permanently rejects the read. `@unchecked Sendable`
/// is limited to transporting that guarded pointer to the reader actor.
struct TerminalSurfaceRuntimeScreenTailRequest: @unchecked Sendable {
    let surface: ghostty_surface_t
    let maxRows: Int
    let maxBytes: Int
    let nativeAccessGate: TerminalSurfaceRuntimeNativeAccessGate

    func read() -> String? {
        var text = ghostty_text_s()
        guard ghostty_surface_read_screen_tail_vt(
            surface,
            UInt(maxRows),
            UInt(maxBytes),
            &text
        ) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let bytes = text.text,
              let byteCount = Int(exactly: text.text_len),
              byteCount > 0 else {
            return nil
        }
        return String(bytes: Data(bytes: bytes, count: byteCount), encoding: .utf8)
    }
}
