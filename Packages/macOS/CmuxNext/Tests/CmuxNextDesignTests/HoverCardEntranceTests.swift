import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-07: "do we want to make it, like, morph together with the tab? ... I wanted to have goo,
/// right? Like the things morph into each other ... that water surface tension thing". A tab card's
/// first show has three entrances: it grows out of its tab (`.morph`), fades in while it slides away
/// from it (`.slide`, every other card's), or fades in where it rests (`.fade`).
@MainActor @Suite(.serialized, .closesItsWindows) struct HoverCardEntranceTests {
    private struct Fixture {
        let parent: NSWindow
        let panel: HoverCardPanel
        let body: NSView
        /// A tab 180 pt wide at the parent's top; the card (240 pt) hangs below it.
        var tab: CGRect { CGRect(x: parent.frame.minX + 40, y: parent.frame.maxY - 60, width: 180, height: 28) }

        func show(_ entrance: HoverCardEntrance) {
            panel.present(body: body, anchor: tab, placement: .below, parent: parent, themeAnchor: nil, sliding: false,
                          entrance: entrance, applyTheme: {})
        }

        /// The translation the entrance slide starts from (nil: no slide runs).
        var slideStart: CGVector? {
            guard let layer = panel.contentView?.layer,
                  let slide = layer.animation(forKey: "sublayerTransform") as? CABasicAnimation,
                  let from = (slide.fromValue as? NSValue)?.caTransform3DValue else { return nil }
            return CGVector(dx: from.m41, dy: from.m42)
        }

        func tearDown() {
            panel.closeAfterTest()
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

    @Test func aMorphingCardGrowsOutOfItsTabFromTheTabsWidth() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }

        f.show(.morph)
        let morph = try #require(f.panel.activeMorph, "the card did not grow out of its tab")
        let grow = try #require(morph.mask.animation(forKey: "bounds") as? CABasicAnimation)
        let from = try #require((grow.fromValue as? NSValue)?.rectValue)
        #expect(abs(from.width - f.tab.width) < 0.5, "the card grows from \(from.width) pt, not its tab's \(f.tab.width)")
        #expect(from.height < 90, "the card starts at its full height \(from.height)")
        // It grows down from the tab's bottom edge, its leading edge on the tab's: no slide.
        #expect(morph.corner == CGPoint(x: 0, y: 1))
        #expect(abs(f.panel.restCardFrame.maxY - f.tab.minY) < 0.5 && abs(f.panel.restCardFrame.minX - f.tab.minX) < 0.5)
        if let start = f.slideStart { #expect(abs(start.dx) < 0.5 && abs(start.dy) < 0.5, "the growing card slid from \(start)") }
    }

    @Test func aFadingCardNeitherSlidesNorGrows() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }

        f.show(.fade)
        #expect(f.panel.activeMorph == nil)
        #expect(f.slideStart == nil, "the fading card slid")
        #expect(f.panel.isVisible)
    }

    @Test func aSlidingCardKeepsTheStandardEntrance() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }

        f.show(.slide)
        #expect(f.panel.activeMorph == nil)
        #expect(f.slideStart == HoverCardPanel.entryVector(for: .below))
    }

    @Test func reduceMotionOnlyFadesAMorphingCard() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }

        f.show(.morph)
        #expect(f.panel.activeMorph == nil, "the card grew under Reduce Motion")
        #expect(f.panel.isVisible)
    }
}
