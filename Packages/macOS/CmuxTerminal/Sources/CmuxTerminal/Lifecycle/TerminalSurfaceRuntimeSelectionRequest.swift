internal import Foundation
internal import GhosttyKit

/// Performs one bounded native selection read while teardown ordering is serialized.
///
/// The raw pointer is borrowed from ``TerminalSurface`` and transported only to the
/// teardown coordinator actor. The request performs no suspension while using it, so
/// a queued native free cannot interleave with the C calls.
struct TerminalSurfaceRuntimeSelectionRequest: @unchecked Sendable {
    let surface: ghostty_surface_t
    let maxBytes: Int

    func read() -> TerminalSurfaceSelectionRead {
        guard maxBytes > 0, let boundedMaxBytes = UInt(exactly: maxBytes) else {
            return .unavailable
        }
        guard ghostty_surface_has_selection(surface) else {
            return .none
        }

        var selection = ghostty_text_s()
        guard ghostty_surface_read_selection_clipboard_text(
            surface,
            boundedMaxBytes,
            &selection
        ) else {
            return .unavailable
        }
        defer { ghostty_surface_free_text(surface, &selection) }

        guard let bytes = selection.text, selection.text_len > 0 else {
            return .selected(text: "")
        }
        let byteCount = Int(clamping: selection.text_len)
        return .selected(text: String(
            decoding: Data(bytes: bytes, count: byteCount),
            as: UTF8.self
        ))
    }
}
