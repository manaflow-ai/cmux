import AppKit
@testable import CmuxNextDesign
import Testing

/// Scratch (never lands): the debug.frames window probe names each window that had a layout pass.
@MainActor @Suite(.serialized) struct WindowPassProbeScratchTests {
    final class Needy: NSView {
        var layouts = 0
        override func layout() { super.layout(); layouts += 1 }
    }

    static func window<W: NSWindow>(_ make: () -> W) -> (W, Needy) {
        let window = make()
        window.isReleasedWhenClosed = false
        let view = Needy(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView = view
        return (window, view)
    }

    @Test func eachPassIsCountedForItsWindowRole() throws {
        LayoutPassGuard.shared.install()
        let (panel, panelView) = Self.window { OverlayHostPanel() }
        let (plain, plainView) = Self.window { NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false) }
        defer { panel.close(); plain.close() }
        var counts = FrameLayoutCounts()
        panelView.needsLayout = true; panel.layoutIfNeeded()
        #expect(LayoutPassGuard.shared.windowPassCounts.isEmpty, "counted per window before the probe started")
        plain.layoutIfNeeded()
        counts.reset()
        // Frame 1: the panel twice, the plain window once.
        panelView.needsLayout = true; panel.layoutIfNeeded()
        panelView.needsLayout = true; panel.layoutIfNeeded()
        plainView.needsLayout = true; plain.layoutIfNeeded()
        counts.frame(records: true)
        // Frame 2: nothing.
        counts.frame(records: true)
        let report = counts.report(raw: true)
        print("S1B-PROBE \(report)")
        let roles = try #require(report["window_passes"] as? [String: [String: Int]])
        #expect(roles["overlay panel"]?["passes"] == 2 && roles["overlay panel"]?["frames_2_plus"] == 1, "\(roles)")
        #expect(roles["NSWindow \(plain.windowNumber)"]?["passes"] == 1, "\(roles)")
        let perFrame = try #require(report["window_passes_per_frame"] as? [[String: Int]])
        #expect(perFrame.count == 2 && perFrame[1].isEmpty, "\(perFrame)")
        #expect(report["window_layouts"] as? Int == 3, "\(report)")
        counts.stop()
        #expect(!LayoutPassGuard.shared.countsPassesByWindow, "counting per window stayed on after stop")
        panelView.needsLayout = true; panel.layoutIfNeeded()
        #expect(LayoutPassGuard.shared.windowPassCounts.isEmpty, "a pass was counted per window after stop")
    }
}
