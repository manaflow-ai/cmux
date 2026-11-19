import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-18, a recording of the pointer crossing two agent tabs: "the hover preview bounces for some
/// reason". Frame by frame (30 fps) the card slid from the last tab to the next on the `.panel` spring and
/// eased into place over about 200 ms while its content crossfaded: the glide (TabHoverCardGlideTests). A
/// card that hangs from its target (a tab's, a group chip's, a Home link chip's) now switches in place by
/// default: under the next target with that target's content in the same frame, with no slide, no
/// crossfade and no resize on a spring, also when the pointer reaches the next tab while the last card fades
/// out. `.crossfade` switches in place with only the content fading.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabHoverCardSwitchInPlaceTests {
    private struct Fixture {
        let parent: NSWindow
        let panel: HoverCardPanel
        let clock: Clock

        /// Tab `index`'s frame on screen: tabs 220 pt wide along the window's top.
        func tab(_ index: CGFloat) -> CGRect {
            CGRect(x: parent.frame.minX + 20 + index * 220, y: parent.frame.maxY - 40, width: 220, height: 32)
        }

        func present(tab index: CGFloat, body: NSView, after: CFTimeInterval = 1, placement: HoverCardPlacement = .below,
                     retarget: HoverCardRetarget = .jump) {
            clock.time += after
            panel.present(body: body, anchor: tab(index), placement: placement, parent: parent, themeAnchor: nil, sliding: true,
                          retarget: retarget, applyTheme: {})
        }

        /// The translation a slide in flight starts from (nil: none runs).
        var slideStart: CGVector? {
            guard let slide = panel.contentView?.layer?.animation(forKey: "sublayerTransform") as? CABasicAnimation,
                  let from = (slide.fromValue as? NSValue)?.caTransform3DValue else { return nil }
            return CGVector(dx: from.m41, dy: from.m42)
        }

        var crossfade: CAAnimation? { panel.glass.contentView.layer?.animation(forKey: HoverCardPanel.crossfadeKey) }

        func tearDown() {
            panel.closeAfterTest()
            parent.close()
        }
    }

    final class Clock {
        var time: CFTimeInterval = 1_000
    }

    private static func body(width: CGFloat, height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: width), view.heightAnchor.constraint(equalToConstant: height)])
        return view
    }

    private static func fixture() -> Fixture {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 1000, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        let clock = Clock()
        let panel = HoverCardPanel()
        panel.now = { clock.time }
        return Fixture(parent: parent, panel: panel, clock: clock)
    }

    /// The card is at the next tab, at its size, with only the next tab's content, in the frame of the move.
    private static func expectSwitchedInPlace(_ f: Fixture, tab index: CGFloat, last: NSView, next: NSView, size: CGSize,
                                              _ when: String) throws {
        #expect(f.slideStart == nil, "\(when): the card slid to the next tab (the bounce)")
        #expect(f.panel.activeMorph == nil, "\(when): the card resized on a spring")
        #expect(f.crossfade == nil, "\(when): the content crossfaded")
        #expect(f.panel.leavingBody == nil && (last.superview == nil || last.isHidden), "\(when): the last tab's content lingers")
        #expect(next.superview === f.panel.glass.contentView && !next.isHidden && next.layer.map { $0.opacity == 1 } != false,
                "\(when): the next tab's content is not shown whole")
        #expect(CATransform3DIsIdentity(try #require(f.panel.contentView?.layer).sublayerTransform), "\(when): the card is off its rest place")
        #expect(abs(f.panel.cardFrame.minX - f.tab(index).minX) < 0.5, "\(when): the card is not under its tab")
        #expect(abs(f.panel.cardFrame.width - size.width) < 0.5 && abs(f.panel.cardFrame.height - size.height) < 0.5,
                "\(when): the card is \(f.panel.cardFrame.size), not the next tab's \(size)")
        #expect(f.panel.lastPresent.inPlace, "\(when): last_present does not say in_place")
    }

    @Test func movingToTheNextTabSwitchesTheCardInPlace() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let a = Self.body(width: 240, height: 120), b = Self.body(width: 260, height: 60)

        f.present(tab: 0, body: a)
        f.present(tab: 1, body: b)
        try Self.expectSwitchedInPlace(f, tab: 1, last: a, next: b, size: CGSize(width: 260, height: 60), "the next tab")
        // Back again, and on to a far tab, each a rested move and each one frame after the last.
        f.present(tab: 0, body: a)
        try Self.expectSwitchedInPlace(f, tab: 0, last: b, next: a, size: CGSize(width: 240, height: 120), "back")
        f.present(tab: 3, body: b, after: 0.016)
        try Self.expectSwitchedInPlace(f, tab: 3, last: a, next: b, size: CGSize(width: 260, height: 60), "a far tab")
    }

    /// The first show grows out of its tab (`HoverCardEntrance.morph`); a move to the next tab mid-growth puts
    /// the whole card at the next tab, with no growth continuing from the last one.
    @Test func aMoveDuringTheEntranceSwitchesInPlace() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let a = Self.body(width: 240, height: 120), b = Self.body(width: 240, height: 120)

        f.clock.time += 1
        f.panel.present(body: a, anchor: f.tab(0), placement: .below, parent: f.parent, themeAnchor: nil, sliding: false,
                        entrance: .morph, applyTheme: {})
        f.present(tab: 1, body: b, after: 0.05)
        try Self.expectSwitchedInPlace(f, tab: 1, last: a, next: b, size: CGSize(width: 240, height: 120), "mid-entrance")
    }

    /// The pointer left the last tab and its card started to fade out; reaching the next tab in the reshow
    /// window shows that tab's card at that tab, fading back in from where the fade was, never a slide.
    @Test func theNextTabDuringTheFadeOutSwitchesInPlace() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let a = Self.body(width: 240, height: 60), b = Self.body(width: 240, height: 60)

        f.present(tab: 0, body: a)
        f.panel.dismiss()
        f.present(tab: 1, body: b, after: 0.05)
        try Self.expectSwitchedInPlace(f, tab: 1, last: a, next: b, size: CGSize(width: 240, height: 60), "during the fade-out")
        #expect(f.panel.isShowingCard, "the card kept fading out")
    }

    /// A card above its target (a tab bar at the bottom, a Home link chip) switches in place too.
    @Test func aCardAboveItsTargetSwitchesInPlace() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let a = Self.body(width: 240, height: 60), b = Self.body(width: 240, height: 90)

        f.present(tab: 0, body: a, placement: .above)
        f.present(tab: 1, body: b, placement: .above)
        try Self.expectSwitchedInPlace(f, tab: 1, last: a, next: b, size: CGSize(width: 240, height: 90), "above")
    }

    /// `.crossfade`: the card is at the next tab at once; only its content fades over the last.
    @Test func crossfadeSwitchesInPlaceWithItsContentFading() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let a = Self.body(width: 240, height: 60), b = Self.body(width: 240, height: 60)

        f.present(tab: 0, body: a, retarget: .crossfade)
        f.present(tab: 1, body: b, retarget: .crossfade)
        #expect(f.slideStart == nil, "the card slid")
        #expect(f.panel.activeMorph == nil, "the card resized on a spring")
        #expect(abs(f.panel.cardFrame.minX - f.tab(1).minX) < 0.5, "the card is not under its tab")
        #expect(f.crossfade != nil, "the content did not crossfade")
    }

    /// A sidebar row's card (`.beside`, `.besideRow`) keeps its own short slide between rows (msg 15501).
    @Test func aSidebarCardStillSlidesBetweenRows() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let a = Self.body(width: 240, height: 60), b = Self.body(width: 240, height: 60)

        f.present(tab: 0, body: a, placement: .beside)
        f.present(tab: 0.2, body: b, placement: .beside)
        #expect(f.slideStart != nil, "a sidebar card stopped sliding between rows")
        #expect(!f.panel.lastPresent.inPlace)
    }
}
