public import Foundation
public import GhosttyKit

extension TerminalSurface {
    /// Reads a byte-bounded VT reconstruction of the newest physical terminal rows.
    ///
    /// Ghostty selects the history suffix and formats it into a fixed-size buffer
    /// before any bytes cross into Swift. The result therefore preserves rendered
    /// styles, conceal, wide characters, and graphemes without exposing raw PTY
    /// output or requiring a render-grid JSON snapshot.
    ///
    /// - Parameters:
    ///   - maxRows: Maximum number of physical history/current-screen rows to include.
    ///   - maxBytes: Hard maximum for the formatted VT byte buffer.
    /// - Returns: A complete UTF-8 VT reconstruction, or `nil` when no bounded snapshot is available.
    @MainActor
    public func boundedScreenTailVT(maxRows: Int, maxBytes: Int) -> String? {
        guard maxRows > 0,
              maxBytes > 0,
              let surface = liveSurfaceForGhosttyAccess(reason: "boundedScreenTailVT") else {
            return nil
        }

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
