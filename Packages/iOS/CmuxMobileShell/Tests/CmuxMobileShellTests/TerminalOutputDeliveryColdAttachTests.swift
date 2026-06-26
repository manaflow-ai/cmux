import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

/// A surface's first full frame cold-attaches (ESC c reset + scrollback seed);
/// every later full frame repaints the viewport in place so a divergence repair
/// (or resize/resync) never resets the scroll position of a reader scrolled up
/// into history.

@Test func coldAttachFullFrameResetsTheTerminal() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "s", stateSeq: 1, columns: 8, rows: 3, text: "alpha\nbeta\n"
    )
    let delivery = TerminalOutputDelivery(renderGrid: frame, replaceable: false, coldAttach: true)
    #expect(String(decoding: delivery.bytes, as: UTF8.self).contains("\u{1B}c"))
}

@Test func postColdAttachFullFrameRepaintsViewportWithoutReset() throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "s", stateSeq: 1, columns: 8, rows: 3, text: "alpha\nbeta\n"
    )
    let delivery = TerminalOutputDelivery(renderGrid: frame, replaceable: false, coldAttach: false)
    let text = String(decoding: delivery.bytes, as: UTF8.self)
    // Scroll-safe repair: no hard reset, but it does clear+repaint viewport rows.
    #expect(!text.contains("\u{1B}c"))
    #expect(text.contains("\u{1B}[2K"))
    #expect(text.contains("alpha"))
}
