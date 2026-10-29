import AppKit
@testable import CmuxNextTerminal
import Testing

/// The terminal's I-beam comes from a cursor area AppKit supports. NSTrackingArea.h does
/// not support `.activeAlways` with `.cursorUpdate`, and with no cursor rect left that area was the only
/// thing to set the I-beam when the pointer entered a terminal from a divider, the sidebar or a browser.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalCursorAreaTests {
    @Test func theIBeamAreaIsActiveInTheKeyWindowNotAlways() {
        let harness = TerminalPointerCoalescingTests.Harness(coalesced: false)
        defer { harness.close() }
        let view = harness.view
        view.updateTrackingAreas()
        let cursorAreas = view.trackingAreas.filter { $0.options.contains(.cursorUpdate) }
        #expect(cursorAreas.contains { $0.options.contains(.activeInKeyWindow) && $0.options.contains(.inVisibleRect) }, "the I-beam's area")
        #expect(!cursorAreas.contains { $0.options.contains(.activeAlways) }, "no cursor updates on the always-active area")
        #expect(view.trackingAreas.contains { $0.options.contains(.mouseMoved) && $0.options.contains(.activeAlways) },
                "moves still arrive in any window")

        // AppKit rebuilds the pointer area on every geometry change; the cursor area stays one.
        view.updateTrackingAreas()
        #expect(view.trackingAreas.filter { $0.options.contains(.cursorUpdate) }.count == cursorAreas.count)
    }
}
