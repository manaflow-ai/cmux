import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-21: "new space plus button needs to be right next to the last space too". The
/// "+" (shown on hover) sits right after the last space's dot, with the same gap the dots have
/// between each other, at every bar width and space count; it follows the last dot as spaces are
/// added or removed and never leaves the bar.
@MainActor @Suite(.serialized) struct ProfileBarPlusPlacementTests {
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
}
