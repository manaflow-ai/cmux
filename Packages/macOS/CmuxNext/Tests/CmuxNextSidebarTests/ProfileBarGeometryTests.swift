import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Leo's dogfood (2026-10-07): the space dots at the sidebar bottom were too
/// small, and a selection change looked like a layout shift. Each dot now
/// has a fixed slot of at least 24 pt (the footer buttons' size), draws a
/// larger mark, and a selection change only changes fill and opacity: no
/// dot moves or changes size, and the bar itself stays in place.
@MainActor @Suite(.serialized) struct ProfileBarGeometryTests {
    static let profiles = [SidebarProfile(id: ProfileKey("default"), name: "Default"),
                           SidebarProfile(id: ProfileKey("p2"), name: "Work"),
                           SidebarProfile(id: ProfileKey("p3"), name: "Play")]

    private func bar(_ model: SidebarModel) -> ProfileBarView {
        let view = ProfileBarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: Metrics.sidebarRowHeight)
        return view
    }

    /// The drawn box of each mark: the marks layer rendered offscreen (not
    /// the current-space chip under it), every pixel with any alpha counted,
    /// grouped by slot (bar points, top-left origin).
    private func dotBoxes(_ view: ProfileBarView, count: Int = 3) throws -> [CGRect] {
        view.layoutSubtreeIfNeeded()
        let marks = view.marks
        let rep = try #require(marks.bitmapImageRepForCachingDisplay(in: marks.bounds))
        marks.cacheDisplay(in: marks.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / marks.bounds.width
        let slots = view.slotRects()
        return try (0..<count).map { index in
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            let from = Int(slots[index].minX * scale), to = Int(slots[index].maxX * scale)
            for y in 0..<rep.pixelsHigh {
                for x in max(0, from)..<min(rep.pixelsWide, to) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            try #require(maxX >= minX, "dot \(index) draws")
            return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                          width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        }
    }

    @Test func aSelectionChangeMovesOrResizesNoDot() throws {
        let model = SidebarModel()
        model.profiles = Self.profiles
        model.activeProfileID = ProfileKey("default")
        let view = bar(model)
        let before = try dotBoxes(view)
        for active in ["p2", "p3", "default"] {
            model.activeProfileID = ProfileKey(active)
            view.refresh()
            for (now, was) in zip(try dotBoxes(view), before) {
                #expect(abs(now.midX - was.midX) <= 0.5 && abs(now.midY - was.midY) <= 0.5
                        && abs(now.width - was.width) <= 1 && abs(now.height - was.height) <= 1,
                        "selecting \(active) moved or resized a dot: \(was) -> \(now)")
            }
        }
    }

    @Test func dotsAreBigEnoughToSeeAndToHit() throws {
        let model = SidebarModel()
        model.profiles = Self.profiles
        model.activeProfileID = ProfileKey("p2")
        #expect(Metrics.roomDotSlot >= 24, "hit width \(Metrics.roomDotSlot)")
        #expect(Metrics.roomDotSlot >= Metrics.sidebarRowHeight, "a dot's slot is as wide as a footer button")
        for box in try dotBoxes(bar(model)) {
            #expect(box.width >= 6 && box.height >= 8, "mark \(box.size)")
        }
    }

    /// The bar keeps its frame in the sidebar across a selection change and
    /// when a space is added; only the dots row grows by whole slots.
    @Test func theBarStaysInPlaceWhenSpacesChange() {
        let model = SidebarModel()
        model.profiles = Array(Self.profiles.prefix(2))
        model.activeProfileID = ProfileKey("default")
        let sidebar = SidebarView(model: model)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        let frame = sidebar.convert(sidebar.profileBar.frame, from: sidebar.profileBar.superview)
        model.activeProfileID = ProfileKey("p2")
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.convert(sidebar.profileBar.frame, from: sidebar.profileBar.superview) == frame)
        model.profiles = Self.profiles
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.convert(sidebar.profileBar.frame, from: sidebar.profileBar.superview) == frame)
    }

    /// cx-5k3r ("spaces animation is jank"): a switch slides the current
    /// space's chip from the old space to the new one, even though the
    /// sidebar's layout pass reaches the bar before its refresh. Reduce
    /// Motion snaps.
    @Test(arguments: [false, true])
    func aSwitchSlidesTheChipOnce(_ reduceMotion: Bool) throws {
        Motion.reduceMotionOverride = reduceMotion
        defer { Motion.reduceMotionOverride = nil }
        let model = SidebarModel()
        model.profiles = Self.profiles
        model.activeProfileID = ProfileKey("default")
        let sidebar = SidebarView(model: model)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        let bar = sidebar.profileBar
        let before = bar.indicator.frame
        model.activeProfileID = ProfileKey("p3")
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        let target = try #require(bar.indicatorRect)
        #expect(bar.indicator.frame == target && target != before, "the chip ends on the new space: \(before) -> \(bar.indicator.frame)")
        let slide = bar.indicator.layer?.animation(forKey: "position")
        #expect((slide != nil) == !reduceMotion, "one slide unless Reduce Motion: \(String(describing: slide))")
    }
}
