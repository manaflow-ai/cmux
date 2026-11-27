import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-21: "new space plus button needs to be right next to the last space too". The
/// "+" (always shown, Leo 2026-11-03) sits right after the last space's dot, with the same gap the dots have
/// between each other, at every bar width and space count; it follows the last dot as spaces are
/// added or removed and never leaves the bar.
@MainActor @Suite(.serialized, .closesItsWindows) struct ProfileBarPlusPlacementTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let count: Int
        let width: CGFloat
        var testDescription: String { "\(count) spaces, \(Int(width)) pt" }
    }

    /// Every count and width where the strip fits (full slots, narrowed slots and compact dots);
    /// a strip too long for its bar is clipped, which is not this rule.
    nonisolated static let cases: [Case] = [1, 2, 5].flatMap { count in
        [120, 160, 240, 400].map { Case(count: count, width: CGFloat($0)) }
    } + [240, 400].map { Case(count: 12, width: CGFloat($0)) }

    @Test func oneProfileStillMountsTheProfileBar() {
        #expect(ProfileBarLogic.isVisible(profileCount: 1))
        #expect(!ProfileBarLogic.isVisible(profileCount: 0))
    }

    /// A bar with `count` spaces (the first current), at rest, in a window.
    private func makeBar(count: Int, width: CGFloat) -> (ProfileBarView, NSWindow) {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.profiles = (0..<count).map { SidebarProfile(id: ProfileKey("space\($0)"), name: "Space \($0)") }
        model.activeProfileID = model.profiles.first?.id
        let view = ProfileBarView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 28), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.refresh()
        return (view, window)
    }

    private func chip(_ slot: NSRect) -> NSRect { ProfileBarLogic.chipRect(slot: slot, inset: Metrics.space1) }

    private func expectPlusFollowsLastDot(_ view: ProfileBarView, _ label: String) {
        let rects = view.slotRects()
        let count = view.model.profiles.count
        guard count > 0, let plus = rects.last else { return }
        let last = rects[count - 1]
        // The same gap the dots' chips have between each other (one dot alone: the chip inset twice).
        let dotGap = count > 1 ? chip(rects[1]).minX - chip(rects[0]).maxX : Metrics.space1 * 2
        let plusGap = chip(plus).minX - chip(last).maxX
        #expect(abs(plusGap - dotGap) <= 0.5, "\(label): the + chip \(chip(plus)) is \(plusGap) pt after the last dot \(chip(last)), the dots \(dotGap) pt apart")
        #expect(plus.maxX <= view.bounds.maxX + 0.5, "\(label): the + \(plus) leaves the bar \(view.bounds)")
        #expect(plus.minX >= last.maxX - 0.5, "\(label): the + \(plus) covers the last dot \(last)")
    }

    @Test(arguments: cases) func thePlusSitsRightAfterTheLastSpace(_ c: Case) {
        let (view, window) = makeBar(count: c.count, width: c.width)
        defer { window.close() }
        expectPlusFollowsLastDot(view, c.testDescription)
    }

    @Test func thePlusFollowsTheLastSpaceAsSpacesComeAndGo() {
        let (view, window) = makeBar(count: 3, width: 240)
        defer { window.close() }
        expectPlusFollowsLastDot(view, "3 spaces")
        let atThree = view.slotRects().last!.minX
        view.model.profiles.append(SidebarProfile(id: ProfileKey("space3"), name: "Space 3"))
        view.refresh()
        expectPlusFollowsLastDot(view, "a space added")
        #expect(view.slotRects().last!.minX != atThree, "the + stayed where it was when a space was added")
        view.model.profiles.removeLast(2)
        view.refresh()
        expectPlusFollowsLastDot(view, "two spaces removed")
    }

    /// Leo 2026-11-03: "I don't want hovering near the row to also just immediately turn it to a plus.
    /// only when im direclty over it. or, rather, why do we not just have the plus to the right of the
    /// center circle? always to the rightmost of the circles". At rest the + is drawn, rightmost of every
    /// drawn dot; the pointer entering the row or hovering a dot turns no dot into a + and moves nothing.
    @Test(arguments: [1, 3, 12]) func thePlusIsThereAtRestAndNearHoverTurnsNoDotIntoAPlus(_ count: Int) {
        let (view, window) = makeBar(count: count, width: 240)
        defer { window.close() }
        let rest = view.slotRects()
        let plus = rest[count]
        #expect(view.plusIsDrawn, "the + is not drawn at rest")
        #expect(view.drawnDotCount == count, "a dot is missing at rest")
        for index in view.drawnDotIndices {
            #expect(rest[index].maxX <= plus.minX + 0.5, "dot \(index) \(rest[index]) is not left of the + \(plus)")
        }
        #expect(view.interactionIndex(at: NSPoint(x: plus.midX, y: plus.midY)) == ProfileBarView.plusIndex)

        view.setPointerInside(true)
        for index in 0..<count {
            view.setHovered(index)
            #expect(view.slotRects() == rest, "hovering dot \(index) moved the strip")
            #expect(view.drawnDotCount == count, "hovering dot \(index) hid a dot")
            let slot = rest[index]
            #expect(view.interactionIndex(at: NSPoint(x: slot.midX, y: slot.midY)) == index,
                    "dot \(index) resolves to \(String(describing: view.interactionIndex(at: NSPoint(x: slot.midX, y: slot.midY)))) under the pointer")
        }
        view.setHovered(nil)
        view.setPointerInside(false)
        #expect(view.slotRects() == rest && view.plusIsDrawn, "leaving the row changed the + or the dots")
    }

    /// Too many spaces for the row even as compact dots: the row scrolls so the current space stays in view,
    /// and the + stays pinned on the trailing edge, rightmost.
    @Test func anOverflowingRowScrollsToTheCurrentSpaceWithThePlusPinnedRightmost() {
        let (view, window) = makeBar(count: 40, width: 160)
        defer { window.close() }
        #expect(view.strip.scrolled, "the fixture does not overflow")
        for active in [0, 20, 39] {
            view.model.activeProfileID = view.model.profiles[active].id
            view.refresh()
            let rects = view.slotRects()
            let plus = rects[40]
            #expect(view.plusIsDrawn)
            #expect(plus.maxX <= view.bounds.maxX + 0.5 && plus.maxX >= view.bounds.maxX - Metrics.roomDotSlot,
                    "the + \(plus) is not on the trailing edge of \(view.bounds)")
            #expect(view.dotIsDrawn(at: active), "the current space \(active) scrolled out of view")
            #expect(rects[active].maxX <= plus.minX + 0.5, "the current space \(active) sits under the +")
            for index in view.drawnDotIndices {
                #expect(rects[index].maxX <= plus.minX + 0.5, "dot \(index) is drawn right of the +")
            }
        }
    }

    /// The gallery's other choice: the + rides the end of the scrolled dots (off the bar until the end is shown).
    @Test func thePlusCanRideTheEndOfTheScrolledDots() {
        let (view, window) = makeBar(count: 40, width: 160)
        defer { window.close() }
        view.plusRidesContent = true
        #expect(!view.plusIsDrawn, "the + rode past the bar but still draws")
        view.model.activeProfileID = view.model.profiles[39].id
        view.refresh()
        let rects = view.slotRects()
        #expect(view.plusIsDrawn)
        #expect(abs(rects[40].minX - rects[39].maxX) <= 0.5, "the riding + is not right after the last dot")
    }

    @Test func clickingThePlusAtRestSendsNewProfile() {
        let (view, window) = makeBar(count: 1, width: 120)
        defer { window.close() }
        var intents: [SidebarIntent] = []
        view.model.onIntent = { intents.append($0) }
        let plus = view.slotRects().last!
        #expect(view.bounds.contains(plus), "the + target must be fully inside the bar")
        let point = NSPoint(x: plus.midX, y: plus.midY)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown))
        view.mouseUp(with: event(.leftMouseUp))
        #expect(intents.contains { if case .newProfile = $0 { true } else { false } },
                "clicking the + did not create a new profile: \(intents)")
    }
}
