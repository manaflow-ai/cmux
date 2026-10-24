import AppKit
@testable import CmuxNextDesign
import Testing

/// Geometry reports (`PointerHover.refresh(in:)`) coalesce into one pass per window per main run
/// loop turn. A sidebar reload reports once per row it configures, and each report recomputed
/// every hover target of the window: O(rows x targets), up to 476 ms of main thread in one STRESS
/// density change (sweep 2026-10-23).
@MainActor
@Suite(.serialized)
struct PointerHoverTurnTests {
    private func window(targets: Int) -> (NSWindow, [PointerHover]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        var hovers: [PointerHover] = []
        for index in 0..<targets {
            let view = NSView(frame: NSRect(x: 0, y: CGFloat(index), width: 100, height: 1))
            window.contentView?.addSubview(view)
            hovers.append(PointerHover(view))
        }
        return (window, hovers)
    }

    @Test func manyReportsInOneTurnMakeOnePass() {
        let (window, hovers) = window(targets: 40)
        defer { window.close() }
        PointerHover.flushChanged()
        let before = PointerHover.windowPasses
        for _ in 0..<60 { PointerHover.refresh(in: window) }
        #expect(PointerHover.windowPasses == before, "reports wait for the turn's flush")
        PointerHover.flushChanged()
        #expect(PointerHover.windowPasses == before + 1, "one pass for 60 reports")
        _ = hovers
    }
}
