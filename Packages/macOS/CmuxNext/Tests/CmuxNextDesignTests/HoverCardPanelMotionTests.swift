import AppKit
@testable import CmuxNextDesign
import Testing

/// Lawrence 2026-10-18: "the card needs proper fade in and translation animation (when hover to
/// different consecutive cards)". A first show starts a few points toward its target and slides
/// out while it fades in; a retarget puts the window at the new place at once (R131: a
/// window-frame slide trailed the pointer) and slides the card there inside the window, at most
/// `HoverCardPanel.travel` points; Reduce Motion keeps only the fades.
@MainActor @Suite(.serialized) struct HoverCardPanelMotionTests {
    private static let rowHeight: CGFloat = 40

    private struct Fixture {
        let parent: NSWindow
        let panel: HoverCardPanel
        let body: NSView

        /// A sidebar row's anchor `row` rows down from the first.
        func anchor(_ row: CGFloat) -> CGRect {
            CGRect(x: parent.frame.minX, y: parent.frame.maxY - 60 - row * rowHeight, width: 200, height: rowHeight)
        }

        let clock: TestClock

        /// Shows the card on `row`, `after` seconds after the last show (default: a rested pointer).
        func present(row: CGFloat, sliding: Bool, after: CFTimeInterval = 1, body: NSView? = nil) {
            clock.time += after
            panel.present(body: body ?? self.body, anchor: anchor(row), placement: .beside, parent: parent, themeAnchor: nil,
                          sliding: sliding, applyTheme: {})
        }

        /// The content crossfade in flight (nil: the content swapped at once).
        var crossfade: CAAnimation? { panel.glass.contentView.layer?.animation(forKey: "hoverCard.crossfade") }

        /// The translation the card's slide starts from (nil: no slide runs).
        var slideStart: CGVector? {
            guard let layer = panel.contentView?.layer,
                  let slide = layer.animation(forKey: "sublayerTransform") as? CABasicAnimation,
                  let from = (slide.fromValue as? NSValue)?.caTransform3DValue else { return nil }
            return CGVector(dx: from.m41, dy: from.m42)
        }

        func tearDown() {
            panel.orderOut(nil)
            parent.close()
        }
    }

    /// The panel's clock: each `present` moves it forward by its `after`.
    final class TestClock {
        var time: CFTimeInterval = 1_000
    }

    private static func fixture() -> Fixture {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalToConstant: 240),
            body.heightAnchor.constraint(equalToConstant: 90),
        ])
        let clock = TestClock()
        let panel = HoverCardPanel()
        panel.now = { clock.time }
        return Fixture(parent: parent, panel: panel, body: body, clock: clock)
    }

    @Test func aFirstShowSlidesOutOfItsTargetAndARetargetSlidesTheCardOver() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }

        f.present(row: 0, sliding: false)
        #expect(f.panel.isVisible)
        // Beside a row: the card starts toward the row (left) and moves out to its place.
        #expect(f.slideStart == HoverCardPanel.entryVector(for: .beside), "the first show did not move in")
        #expect(abs(f.panel.cardFrame.maxY - f.anchor(0).maxY) < 0.5, "the card is not top-aligned with its row")

        // The next row: the window is at the new place in this frame, and the card slides
        // there from one row up (it keeps its top edge), instead of hiding and reappearing.
        f.present(row: 1, sliding: true)
        #expect(abs(f.panel.cardFrame.maxY - f.anchor(1).maxY) < 0.5, "the window trails its target")
        let start = try #require(f.slideStart, "the retarget jumped instead of sliding")
        #expect(abs(start.dy - Self.rowHeight) < 0.5 && abs(start.dx) < 0.5, "the slide starts at \(start)")

        // Far away (a row five down): the slide carries the card at most `travel` points.
        f.present(row: 6, sliding: true)
        let far = try #require(f.slideStart)
        #expect(far.dy <= HoverCardPanel.travel + 0.5, "a far retarget slid \(far.dy) pt, past the window's room")
        #expect(abs(f.panel.cardFrame.maxY - f.anchor(6).maxY) < 0.5)
    }

    @Test func reduceMotionKeepsOnlyTheFades() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }

        f.present(row: 0, sliding: false)
        #expect(f.slideStart == nil, "the first show moved under Reduce Motion")
        f.present(row: 1, sliding: true)
        #expect(f.slideStart == nil, "the retarget slid under Reduce Motion")
        let transform = try #require(f.panel.contentView?.layer).sublayerTransform
        #expect(CATransform3DIsIdentity(transform), "the card is off its place under Reduce Motion")
        #expect(abs(f.panel.cardFrame.maxY - f.anchor(1).maxY) < 0.5)
    }

    /// Lawrence 2026-10-28 (msg 15501, a screen recording): "card animation needs to be better, if
    /// i move across it very fast". Sweeping the sidebar's rows, every row restarted the slide
    /// from where the card was drawn and a content crossfade over a frame still mid-crossfade:
    /// the card trailed the pointer by up to `travel` points and its text doubled. Now a retarget
    /// that comes while the last one is still moving the card is a sweep: the card is at its row
    /// with its new text in that frame (no slide, no crossfade, no resize), as a macOS tooltip in
    /// its warm state; once the pointer rests, the next row glides again.
    @Test func aFastSweepSnapsTheCardToEachRowWithNoSlideOrCrossfade() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let tall = NSView()
        tall.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tall.widthAnchor.constraint(equalToConstant: 240),
            tall.heightAnchor.constraint(equalToConstant: 130),
        ])

        f.present(row: 0, sliding: false)
        f.present(row: 1, sliding: true)
        #expect(f.slideStart != nil, "a rested pointer's retarget no longer glides")

        // One display frame per row, alternating card sizes, as a fast pointer crosses them.
        for row in 2...8 {
            f.present(row: CGFloat(row), sliding: true, after: 0.016, body: row.isMultiple(of: 2) ? tall : f.body)
            #expect(f.slideStart == nil, "row \(row): the sweep restarted the slide, so the card trails the pointer")
            #expect(f.crossfade == nil, "row \(row): the sweep crossfaded over a half-faded frame (doubled text)")
            #expect(f.panel.activeMorph == nil, "row \(row): the sweep resized the card on a spring")
            let transform = try #require(f.panel.contentView?.layer).sublayerTransform
            #expect(CATransform3DIsIdentity(transform), "row \(row): the card is not on its row")
            #expect(abs(f.panel.cardFrame.maxY - f.anchor(CGFloat(row)).maxY) < 0.5, "row \(row): the window is not on its row")
        }

        // The pointer rests, then moves one row: the card glides there again.
        f.present(row: 9, sliding: true, after: 1)
        #expect(f.slideStart != nil, "after the sweep, a rested retarget does not glide")
    }
}
