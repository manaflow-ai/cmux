import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// The badges shown while Cmd is held (cx-vdb7) are Liquid Glass chips: one
/// overlay surface per hint (the opaque theme fill under Reduce Transparency,
/// injected here), each with its shortcut text, right-aligned in its target
/// and never taking clicks.
@MainActor @Suite struct ShortcutHintOverlayGlassTests {
    private func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + descendants(of: $0, as: type) }
    }

    private func overlay(with hints: [ShortcutHintOverlayView.Hint]) -> ShortcutHintOverlayView {
        let overlay = ShortcutHintOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        overlay.hints = hints
        overlay.layoutSubtreeIfNeeded()
        return overlay
    }

    @Test func eachHintIsAGlassChipWithItsShortcut() throws {
        ReduceTransparency.shared.override = false
        defer { ReduceTransparency.shared.override = nil }
        let rows = [CGRect(x: 0, y: 200, width: 220, height: 28), CGRect(x: 0, y: 160, width: 220, height: 28)]
        let view = overlay(with: [.init(text: "⌘1", rect: rows[0]), .init(text: "⌘2", rect: rows[1])])

        let surfaces = descendants(of: view, as: OverlaySurfaceView.self)
        #expect(surfaces.count == 2)
        for surface in surfaces {
            #expect(surface.material == .liquidGlass)
            #expect(surface.materialDrawingView is NSGlassEffectView)
            #expect(!surface.isInteractive)
        }
        let labels = descendants(of: view, as: NSTextField.self).map(\.stringValue)
        #expect(labels.sorted() == ["⌘1", "⌘2"])
        for (surface, row) in zip(surfaces.sorted { $0.frame.minY > $1.frame.minY }, rows) {
            let frame = surface.convert(surface.bounds, to: view)
            #expect(row.contains(frame), "\(frame) outside \(row)")
            #expect(row.maxX - frame.maxX <= 4, "chip is not right-aligned: \(frame) in \(row)")
            #expect(abs(frame.midY - row.midY) <= 1)
        }
        #expect(view.hitTest(CGPoint(x: rows[0].maxX - 6, y: rows[0].midY)) == nil)
    }

    @Test func chipsFollowReduceTransparencyAndTheHintCount() throws {
        ReduceTransparency.shared.override = true
        defer { ReduceTransparency.shared.override = nil }
        let row = CGRect(x: 0, y: 100, width: 200, height: 28)
        let view = overlay(with: [.init(text: "⌘B", rect: row), .init(text: "⌘[", rect: row.offsetBy(dx: 0, dy: 40))])
        #expect(descendants(of: view, as: OverlaySurfaceView.self).allSatisfy { $0.material == .opaque })

        view.hints = [.init(text: "⌘B", rect: row)]
        view.layoutSubtreeIfNeeded()
        #expect(descendants(of: view, as: OverlaySurfaceView.self).count == 1)
        view.hints = []
        view.layoutSubtreeIfNeeded()
        #expect(descendants(of: view, as: OverlaySurfaceView.self).isEmpty)
    }
}
