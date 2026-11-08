import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
import Testing

/// Lawrence 2026-11-08 (cmux-ad m70): pin and unpin "needs to translate properly from its original position to new
/// position": one copy, the same view. A re-pin made a new Pinned item view (`SidebarRegionView.makeItem`, a new
/// subview) and an unpin took the old one out of the window: AppKit built the new view's layer tree at the display flush
/// of the pin's second turn and freed the old one there (pin profile, cmux21 120 Hz, cb761d6: the flush was 5.2 ms of
/// that turn, the largest cut of 26 missed refreshes over 20 keys). An unpin now parks the item view hidden in its
/// region, as the list parks its rows, and the workspace's next pin moves that same view again. The app mints a new
/// item id on each pin (`SidebarLayoutDocument.pinOp`), so the view must come back for the workspace, not the item id.
@MainActor @Suite(.serialized, .closesItsWindows, .enabled(if: !NSScreen.screens.isEmpty))
struct SidebarPinItemReuseTests {
    typealias Pin = SidebarPinFlightTests

    /// The list shows `pins` pinned, the moved workspace's item with the id of pin number `round`.
    static func show(_ pins: [WorkspaceID], round: Int, on list: SidebarListView) {
        var (sections, blocks) = Pin.state(pins)
        let old = LayoutItemID("itm_pin_\(Pin.moved.rawValue)"), minted = LayoutItemID("itm_pin_\(Pin.moved.rawValue)_\(round)")
        let key = SidebarLayoutDocument.pinnedSectionID.rawValue
        if var section = blocks.sections[key], let index = section.items.firstIndex(where: { $0.id == old }) {
            section.items[index] = LayoutItem(id: minted, ref: section.items[index].ref)
            blocks.sections[key] = section
            blocks.infos[minted] = blocks.infos.removeValue(forKey: old)
        }
        list.blocks = blocks
        list.model.sections = sections
        list.reload(animated: true)
        list.layoutSubtreeIfNeeded()
    }

    /// The Pinned item view that draws the moved workspace now.
    static func item(in list: SidebarListView) -> SidebarItemRowView? {
        Pin.copies(of: Pin.moved, in: list).lazy.compactMap { $0 as? SidebarItemRowView }.first { !$0.isHiddenOrHasHiddenAncestor }
    }

    /// Pin, unpin, pin again (each pin a new item id): the second pin moves the view the first one showed, and between
    /// the two the unpin left it in the window, hidden (no layer tree to build again, nothing to free in the frame).
    func checkRepin(motion: Bool) throws {
        let (list, window) = Pin.list(pins: [])
        defer { window.close() }
        Motion.reduceMotionOverride = !motion
        defer { Motion.reduceMotionOverride = nil }
        Self.show([Pin.moved], round: 1, on: list)
        let first = try #require(Self.item(in: list), "the pin shows no Pinned item")
        if motion { Self.land(first) }
        Self.show([], round: 1, on: list)
        #expect(first.window === window, "the unpin took the item view out of the window (the next pin makes a new one)")
        #expect(first.isHiddenOrHasHiddenAncestor, "the unpinned item view still shows: two copies")
        if motion { Self.land(first) }
        Self.show([Pin.moved], round: 2, on: list)
        let second = try #require(Self.item(in: list), "the re-pin shows no Pinned item")
        #expect(second === first, "the re-pin made a new item view instead of moving the one its last pin showed")
        #expect(second.alphaValue == 1, "the re-pinned item view shows at alpha \(second.alphaValue)")
        let shown = Pin.copies(of: Pin.moved, in: list).filter { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0 }
        #expect(shown.count == 1, "\(shown.count) copies of the re-pinned workspace show")
    }

    /// Lets the moves of the last change end (their completions run): a flight's view lands before the next key.
    static func land(_ view: NSView) {
        let end = Date(timeIntervalSinceNow: 1.5)
        while Date() < end, view.layer?.zPosition ?? 0 != 0 || !(view.layer?.animationKeys() ?? []).isEmpty {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    @Test func aRepinMovesTheSameItemViewWithMotionOff() throws { try checkRepin(motion: false) }

    @Test func aRepinMovesTheSameItemViewAfterItsFlight() throws { try checkRepin(motion: true) }
}
