import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-15 (msg 34360, a screen recording of the pointer crossing a tab strip): "this
/// animation needs to be better". Frame by frame: a tab card farther than `HoverCardPanel.travel`
/// jumped most of the way and slid the last 48 pt; a quick move snapped it to each tab; and the
/// content crossfade (one snapshot of the card stretched over the next card's size) drew the last
/// tab's text shifted and doubled over the next, past the card's edge. A tab card is one card: it
/// glides the whole way to the next tab on one spring, retargeted from where it is drawn when the
/// pointer moves on mid-glide, and the last card's content fades out at its own size while the
/// next one's fades in. Reduce Motion: the card is at its tab at once.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabHoverCardGlideTests {
    private struct Fixture {
        let parent: NSWindow
        let panel: HoverCardPanel
        let clock: Clock

        /// Tab `index`'s frame on screen: tabs 220 pt wide along the window's top.
        func tab(_ index: CGFloat) -> CGRect {
            CGRect(x: parent.frame.minX + 20 + index * 220, y: parent.frame.maxY - 40, width: 220, height: 32)
        }

        func present(tab index: CGFloat, body: NSView, after: CFTimeInterval = 1) {
            clock.time += after
            panel.present(body: body, anchor: tab(index), placement: .below, parent: parent, themeAnchor: nil, sliding: true,
                          applyTheme: {})
        }

        /// The translation the card's glide starts from (nil: no glide runs).
        var slideStart: CGVector? {
            guard let slide = panel.contentView?.layer?.animation(forKey: "sublayerTransform") as? CABasicAnimation,
                  let from = (slide.fromValue as? NSValue)?.caTransform3DValue else { return nil }
            return CGVector(dx: from.m41, dy: from.m42)
        }

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

    @Test func aTabCardGlidesTheWholeWayToAFarTab() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let a = Self.body(width: 240, height: 60), b = Self.body(width: 240, height: 60)

        f.present(tab: 0, body: a)
        let drawn = f.panel.presentedCardFrame
        f.present(tab: 2, body: b)
        let start = try #require(f.slideStart, "the card jumped to the far tab")
        #expect(abs(start.dx - (drawn.minX - f.panel.cardFrame.minX)) < 0.5,
                "the glide starts \(start.dx) pt off its rest place, not where the card was drawn (\(drawn.minX - f.panel.cardFrame.minX) pt)")
        // The window holds the card the whole way, so no edge of it is cut off mid-glide.
        #expect(f.panel.frame.contains(drawn), "the window \(f.panel.frame) cuts off the card where it starts (\(drawn))")
        #expect(abs(f.panel.cardFrame.minX - f.tab(2).minX) < 0.5, "the card does not rest under its tab")
    }

    /// The live recording after the first fix: the tab's memory sample lands just after the retarget and
    /// refits the card. That refit ended the morph and put the window back at the card plus its 48 pt
    /// band, so the glide went on in a window that cut off all but the card's last 60 pt: the card
    /// seemed to jump to the next tab and grow out of its left edge. A refit mid-glide waits for it.
    @Test func aRefitMidGlideKeepsTheGlideAndItsWindow() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let a = Self.body(width: 240, height: 60), b = Self.body(width: 240, height: 60)

        f.present(tab: 0, body: a)
        let drawn = f.panel.presentedCardFrame
        f.present(tab: 2, body: b)
        f.panel.refit()
        #expect(f.panel.activeMorph != nil, "a refit ended the glide's morph")
        #expect(f.panel.frame.contains(drawn), "after a refit the window \(f.panel.frame) cuts off the gliding card (\(drawn))")
    }

    /// The live recording of the first fix: when the last card's content finished fading out, it was made
    /// whole again before AppKit took it out of the window, so it flashed back at full strength for one
    /// frame. It leaves clear, and shows whole when its tab's card comes back without a fade.
    @Test func theLeavingContentNeverFlashesBack() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let a = Self.body(width: 240, height: 120), b = Self.body(width: 240, height: 60)

        f.present(tab: 0, body: a)
        f.present(tab: 1, body: b)
        f.panel.endLeaving()
        #expect(a.superview == nil || a.isHidden, "the last content stayed shown in the card")
        #expect(a.layer?.opacity == 0, "the last content was made whole while it left (a one-frame flash)")
        Motion.reduceMotionOverride = true
        f.present(tab: 0, body: a)
        #expect(a.layer?.opacity == 1 && !a.isHidden, "content shown again without a fade stayed clear")
    }

    @Test func movingOnMidGlideRetargetsTheGlideFromWhereTheCardIsDrawn() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let a = Self.body(width: 240, height: 60), b = Self.body(width: 240, height: 60)

        f.present(tab: 0, body: a)
        f.present(tab: 1, body: b)
        // One display frame later, the pointer is on the next tab: no snap to it.
        let drawn = f.panel.presentedCardFrame
        f.present(tab: 2, body: a, after: 0.016)
        let start = try #require(f.slideStart, "a quick move snapped the card to the tab")
        #expect(abs(start.dx - (drawn.minX - f.panel.cardFrame.minX)) < 0.5, "the glide restarted from \(start.dx), not from where the card was")
    }

    @Test func theLastCardsContentFadesOutAtItsOwnSizeWhileTheNextFadesIn() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let tall = Self.body(width: 240, height: 180), short = Self.body(width: 260, height: 50)

        f.present(tab: 0, body: tall)
        f.present(tab: 1, body: short)
        let content = f.panel.glass.contentView
        #expect(content.layer?.animation(forKey: HoverCardPanel.crossfadeKey) == nil,
                "a snapshot crossfade stretches the last card over the next card's size")
        #expect(tall.superview === content, "the last card's content went at once instead of fading out")
        #expect(abs(tall.frame.height - 180) < 0.5 && abs(tall.frame.width - 240) < 0.5, "the leaving content is \(tall.frame.size), not its own size")
        #expect(tall.layer?.animation(forKey: "opacity") != nil, "the leaving content does not fade out")
        #expect(short.layer?.animation(forKey: "opacity") != nil, "the next content does not fade in")
        #expect(f.panel.activeMorph != nil, "the card does not resize on the glide's spring")
    }

    @Test func reduceMotionPutsTheCardAtItsTabAtOnce() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let f = Self.fixture()
        defer { f.tearDown() }
        let tall = Self.body(width: 240, height: 180), short = Self.body(width: 260, height: 50)

        f.present(tab: 0, body: tall)
        f.present(tab: 2, body: short)
        #expect(f.slideStart == nil, "the card glided under Reduce Motion")
        #expect(f.panel.activeMorph == nil, "the card resized on a spring under Reduce Motion")
        #expect(tall.superview == nil, "the last content lingers under Reduce Motion")
        #expect(CATransform3DIsIdentity(try #require(f.panel.contentView?.layer).sublayerTransform))
        #expect(abs(f.panel.cardFrame.minX - f.tab(2).minX) < 0.5)
    }
}
