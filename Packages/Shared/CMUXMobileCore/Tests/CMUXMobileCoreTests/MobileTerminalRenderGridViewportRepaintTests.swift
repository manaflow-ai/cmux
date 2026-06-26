import Foundation
import Testing
@testable import CMUXMobileCore

/// The viewport repaint is the scroll-safe keyframe used to repair a detected
/// divergence. Its defining property: it never resets the terminal, so a repair
/// cannot disturb a scrolled-up reader's scroll position or local scrollback.

@Test func viewportRepaintNeverResetsTheTerminal() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a", stateSeq: 1, columns: 8, rows: 3, text: "alpha\nbeta\ngamma"
    )
    let bytes = MobileTerminalRenderGridReplay(frame).viewportRepaintBytes()
    let text = String(decoding: bytes, as: UTF8.self)

    // No `ESC c` hard reset (the thing that wipes scrollback / yanks scroll).
    #expect(!text.contains("\u{1B}c"))
    // No scrollback flow (no CRLF line feeds that would push history).
    #expect(!text.contains("\r\n"))
    // It DOES clear every viewport row in place and repaint content.
    #expect(text.contains("\u{1B}[2K"))
    #expect(text.contains("alpha"))
    #expect(text.contains("gamma"))
    // Wrapped in a synchronized update so the repair is atomic.
    #expect(text.hasPrefix("\u{1B}[?2026h"))
    #expect(text.hasSuffix("\u{1B}[?2026l"))
}

@Test func viewportRepaintClearsAStaleRow() throws {
    // Authoritative grid blanked row 2; the repaint must clear it (so a stale
    // "gamma" left by a dropped delta is wiped) even though no span repaints it.
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal-a", stateSeq: 1, columns: 8, rows: 3, text: "alpha\nbeta\n"
    )
    let text = String(decoding: MobileTerminalRenderGridReplay(frame).viewportRepaintBytes(), as: UTF8.self)
    // Cursor-position + erase for the third row (1-based row 3) is present.
    #expect(text.contains("\u{1B}[3;1H\u{1B}[2K"))
}
