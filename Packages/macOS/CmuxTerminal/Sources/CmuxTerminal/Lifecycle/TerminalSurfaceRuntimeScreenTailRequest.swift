internal import Foundation
internal import GhosttyKit

/// A bounded native screen-tail read ordered before later teardown requests.
///
/// The raw surface pointer remains owned by its ``TerminalSurface``. The caller
/// admits a native-access borrow before its first suspension, and the runtime
/// coordinator executes this request without suspension while that borrow
/// defers process termination and native free. `@unchecked Sendable` is limited
/// to transporting the borrowed pointer onto the coordinator actor.
struct TerminalSurfaceRuntimeScreenTailRequest: @unchecked Sendable {
    let runtimeLifecycleId: UUID
    let surface: ghostty_surface_t
    let maxRows: Int
    let maxBytes: Int

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
