import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-18: "the card needs proper fade in and translation animation (when hover to
/// different consecutive cards)". A first show starts a few points toward its target and slides
/// out while it fades in; a retarget puts the window at the new place at once (R131: a
/// window-frame slide trailed the pointer) and slides the card there inside the window, at most
/// `HoverCardPanel.travel` points; Reduce Motion keeps only the fades.
@MainActor @Suite(.serialized, .closesItsWindows) struct HoverCardPanelMotionTests {
    private static let rowHeight: CGFloat = 40

    private struct Fixture {
        let parent: NSWindow
        let panel: HoverCardPanel
        let body: NSView

        /// A sidebar row's anchor `row` rows down from the first.
        func anchor(_ row: CGFloat) -> CGRect {
            CGRect(x: parent.frame.minX, y: parent.frame.maxY - 60 - row * rowHeight, width: 200, height: rowHeight)
        }

        func present(row: CGFloat, sliding: Bool) {
            panel.present(body: body, anchor: anchor(row), placement: .beside, parent: parent, themeAnchor: nil,
                          sliding: sliding, applyTheme: {})
        }

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
        return Fixture(parent: parent, panel: HoverCardPanel(), body: body)
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
}
