import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// `sidebar.groupBarShape` (ask-8e5e0aeec3, Leo 2026-10-23: "keep the left thing but I LIKE THE CUT ... JUST MAKE THE
/// CUT THE TAPER ON THE BAR"): Tapered draws the group rail's top as a tip, square on the left and curving out to the
/// right edge, with only the bottom rounded. Rounded, Lawrence's even capsule (2026-11-17), stays the default, unchanged.
@MainActor @Suite struct SidebarGroupBarShapeTests {
    static let all: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    @Test func roundedIsTheDefaultAndUnchanged() {
        #expect(SidebarSectionsPreferences().groupBarShape == .rounded)
        #expect(SidebarGroupLineShape.capCorners(flipped: true, shape: .rounded) == Self.all)
        #expect(SidebarGroupLineShape.body(width: 2, height: 20, shape: .rounded) == SidebarGroupLineShape.body(width: 2, height: 20))
        #expect(SidebarGroupLineShape.body(width: 2, height: 20).contains(CGPoint(x: 1.9, y: 0.1)), "the capsule's body is a full bar")
    }

    @Test func taperedDrawsTheTipOnTop() {
        let path = SidebarGroupLineShape.body(width: 2, height: 20, shape: .tapered)
        #expect(!path.contains(CGPoint(x: 1.9, y: 0.1)), "the top right is cut away by the taper")
        #expect(path.contains(CGPoint(x: 0.1, y: 0.5)), "the left edge runs straight up to the tip")
        #expect(path.contains(CGPoint(x: 1.9, y: 4.1)), "below the taper the bar is full width")
        #expect(path.contains(CGPoint(x: 1.9, y: 19.9)), "the bottom is a full bar the cap clip rounds")
        #expect(SidebarGroupLineShape.capCorners(flipped: true, shape: .tapered) == [.layerMinXMaxYCorner, .layerMaxXMaxYCorner],
                "only the bottom is rounded; the top is the tip")
        #expect(SidebarGroupLineShape.capCorners(flipped: false, shape: .tapered) == [.layerMinXMinYCorner, .layerMaxXMinYCorner])
    }

    @Test func aJoinedRailKeepsItsSquareTop() {
        let joined = SidebarGroupLineShape.body(width: 2, height: 20, shape: .tapered, joined: true)
        #expect(joined.contains(CGPoint(x: 1.9, y: 0.1)), "a rail joined to its header's bar runs square out of it")
        #expect(SidebarGroupLineShape.capCorners(flipped: true, joined: true, shape: .tapered) == [.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
    }

    @Test func switchingTheShapeRedrawsTheList() {
        let before = SidebarSectionsPreferences()
        var after = before
        after.groupBarShape = .tapered
        #expect(after.changesList(from: before))
    }
}
