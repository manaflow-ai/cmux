import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-10-21: "new space plus button needs to be right next to the last space too". The
/// "+" (shown on hover) sits right after the last space's dot, with the same gap the dots have
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
    nonisolated static let cases: [Case] = [2, 5].flatMap { count in
        [120, 160, 240, 400].map { Case(count: count, width: CGFloat($0)) }
    } + [240, 400].map { Case(count: 12, width: CGFloat($0)) }

    @Test func oneProfileStillMountsTheProfileBar() {
        #expect(ProfileBarLogic.isVisible(profileCount: 1))
        #expect(!ProfileBarLogic.isVisible(profileCount: 0))
    }

    /// A bar with `count` spaces (the first current), the pointer over it, in a window.
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
        view.setPointerInside(true)
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

    @Test func showingThePlusMovesNoDot() {
        let (view, window) = makeBar(count: 5, width: 240)
        defer { window.close() }
        let hovered = view.slotRects().dropLast()
        view.setPointerInside(false)
        #expect(Array(view.slotRects().dropLast()) == Array(hovered), "the dots moved when the + hid")
    }

    @Test(arguments: [CGFloat(20), 120, 300])
    func oneSpaceKeepsItsDotAndHoverMakesTheOverlaidPlusReachable(_ width: CGFloat) {
        let (view, window) = makeBar(count: 1, width: width)
        defer { window.close() }
        view.setPointerInside(false)
        #expect(view.drawnDotCount == 1, "the only space's dot disappeared at rest")
        let dot = view.slotRects()[0]
        #expect(view.bounds.contains(dot))
        #expect(view.interactionIndex(at: NSPoint(x: dot.midX, y: dot.midY)) == 0, "the resting dot is not interactive")

        view.setPointerInside(true)
        let plus = view.slotRects().last!
        #expect(view.drawnDotCount == 0, "the dot must give way to +, never paint under it")
        #expect(plus == dot, "hover must not move the shared slot")
        #expect(plus.intersects(dot), "the narrow fixture did not exercise the overlaid plus slot")
        #expect(view.interactionIndex(at: NSPoint(x: plus.midX, y: plus.midY)) == ProfileBarView.plusIndex,
                "hovering the dot's slot did not resolve to +")
    }

    @Test(arguments: [true, false], [true, false])
    func visibilityChoicesNeverDrawDotUnderPlus(_ dotsIdle: Bool, _ plusIdle: Bool) {
        let (view, window) = makeBar(count: 1, width: 120)
        defer { window.close() }
        view.showsDotsWhenIdle = dotsIdle
        view.showsPlusWhenIdle = plusIdle
        view.setPointerInside(false)
        #expect(view.drawnDotCount == (dotsIdle && !plusIdle ? 1 : 0))
        #expect(view.plusIsDrawn == plusIdle)
        view.setPointerInside(true)
        #expect(view.plusIsDrawn)
        #expect(view.drawnDotCount == 0)
        #expect(view.indicatorRect == nil)
    }

    @Test func clickingTheOverlaidPlusSendsNewProfile() {
        let (view, window) = makeBar(count: 1, width: 20)
        defer { window.close() }
        var intents: [SidebarIntent] = []
        view.model.onIntent = { intents.append($0) }
        view.setPointerInside(true)
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
                "clicking the narrow hover slot did not create a new profile: \(intents)")
    }
}
