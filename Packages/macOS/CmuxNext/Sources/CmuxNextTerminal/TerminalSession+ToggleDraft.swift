import Foundation
import GhosttyNextKit

/// Toggle Terminal and Chat's draft on the terminal face: the unsent draft goes with a swap, both
/// ways (Leo, 2026-11-12). The session records what it sends its program (``TerminalTypedTail``);
/// reading the input line out of that is Rust's (cmux-window-rules `tabs::draft`).
extension TerminalSession {
    /// The newest bytes this terminal sent its program, and whether older ones were dropped.
    public var toggleDraftTyped: (bytes: [UInt8], truncated: Bool) { input.typed.read }

    /// Nothing sent since the session started: no draft, and no need to read further.
    public var toggleDraftNothingTyped: Bool { input.typed.isEmpty }

    /// The active rows (the screen's bottom, wherever the viewport is), one line per row. Takes
    /// Ghostty's surface lock: once per swap that has a draft to weigh, never per frame.
    public func toggleDraftScreen() -> String? {
        surfaceView.rowsText(from: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                             to: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0))
    }

    /// Pastes `text` as the person would: Ghostty brackets it when the program asked for that.
    public func toggleDraftPaste(_ text: String) { sendText(text) }

    /// Sends `bytes` as typed (the DELs that erase a carried draft), recorded like every key.
    public func toggleDraftSend(_ bytes: [UInt8]) { sendBytes(Data(bytes)) }
}
