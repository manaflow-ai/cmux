import Testing
@testable import CmuxNextSidebar

/// The room dots at the bottom of the sidebar: visibility, stepping (swipe,
/// next/previous), drag reorder, and the swipe recognizer.
@Suite struct ProfileBarTests {
    private let a = ProfileKey("default"), b = ProfileKey("prof_b"), c = ProfileKey("prof_c")

    /// cx-5k3r: the strip centers on `center`, clamped into the bar; the
    /// "+" sits at the trailing edge and is not part of the centering.
    @Test func theStripCentersAndThePlusStaysAtTheTrailingEdge() {
        func strip(_ count: Int, center: Double, width: Double = 200, active: Int? = 0) -> SpaceStrip {
            ProfileBarLogic.strip(count: count, active: active, width: width, center: center, slot: 20, plus: 20,
                                  fullMinimum: 15, compactMinimum: 8)
        }
        let three = strip(3, center: 100)
        #expect(three.slots.map(\.x) == [70, 90, 110] && three.slots.allSatisfy { $0.width == 20 })
        #expect(three.midX == 100 && !three.compact)
        #expect(three.plus.x == 180 && three.plus.width == 20)
        // Clamped: a center near an edge never pushes a dot out or under the "+".
        #expect(strip(3, center: 10).slots.first?.x == 0)
        #expect(strip(3, center: 190).slots.last.map { $0.x + $0.width } == 180)
        // Too many for full slots: every slot narrows evenly while it can.
        let ten = strip(10, center: 100)
        #expect(!ten.compact && ten.slots.allSatisfy { $0.width == 18 } && ten.slots.first?.x == 0)
        // Then compact: the active space keeps a full slot, the others share the rest.
        let many = strip(19, center: 100, active: 4)
        #expect(many.compact && many.slots[4].width == 20 && many.slots[0].width == 160.0 / 18)
        #expect(abs((many.slots.last.map { $0.x + $0.width } ?? 0) - 180) < 0.001)
    }

    @Test func hiddenWithOneRoom() {
        #expect(!ProfileBarLogic.isVisible(profileCount: 0))
        #expect(!ProfileBarLogic.isVisible(profileCount: 1))
        #expect(ProfileBarLogic.isVisible(profileCount: 2))
    }

    /// Coordinator (2026-10-06): one space drew a stray dot above the footer. The bar stays
    /// mounted (stable chrome), but a lone dot switches nothing, so it draws only with the "+"
    /// while the pointer is over the bar.
    @MainActor @Test func aLoneSpaceDrawsNoDotAtRest() {
        let model = SidebarModel()
        model.profiles = [SidebarProfile(id: a, name: "Default")]
        let bar = ProfileBarView(model: model)
        #expect(bar.drawnDotCount == 0)
        bar.setPointerInside(true)
        #expect(bar.drawnDotCount == 1, "hover shows it with the + for a new space")
        bar.setPointerInside(false)
        model.profiles.append(SidebarProfile(id: b, name: "Work"))
        #expect(bar.drawnDotCount == 2)
    }

    @Test func stepClampsAtTheEnds() {
        #expect(ProfileBarLogic.step(from: a, by: 1, in: [a, b, c]) == b)
        #expect(ProfileBarLogic.step(from: c, by: 1, in: [a, b, c]) == nil)
        #expect(ProfileBarLogic.step(from: a, by: -1, in: [a, b, c]) == nil)
        #expect(ProfileBarLogic.step(from: c, by: -2, in: [a, b, c]) == a)
        #expect(ProfileBarLogic.step(from: nil, by: 1, in: [a, b]) == b)
    }

    @Test func dragInsertionUsesMoveWorkspaceSemantics() {
        let centers = [10.0, 30.0, 50.0]
        #expect(ProfileBarLogic.insertionIndex(forX: 5, centers: centers) == 0)
        #expect(ProfileBarLogic.insertionIndex(forX: 40, centers: centers) == 2)
        #expect(ProfileBarLogic.insertionIndex(forX: 99, centers: centers) == 3)
        // Dragging the first dot past the last lands last; onto itself is no move.
        #expect(ProfileBarLogic.finalIndex(from: 0, insertion: 3, count: 3) == 2)
        #expect(ProfileBarLogic.finalIndex(from: 0, insertion: 1, count: 3) == nil)
        #expect(ProfileBarLogic.finalIndex(from: 2, insertion: 0, count: 3) == 0)
    }

    @Test func swipeFiresOncePerHorizontalGesture() {
        var tracker = ProfileSwipeTracker(threshold: 60)
        #expect(tracker.feed(deltaX: -20, deltaY: 1, phase: .began) == nil)
        #expect(tracker.feed(deltaX: -50, deltaY: 2, phase: .changed) == 1)
        #expect(tracker.feed(deltaX: -80, deltaY: 0, phase: .changed) == nil)
        #expect(tracker.feed(deltaX: 0, deltaY: 0, phase: .ended) == nil)
        #expect(tracker.feed(deltaX: 70, deltaY: 0, phase: .began) == -1)
    }

    @Test func verticalScrollNeverSwitches() {
        var tracker = ProfileSwipeTracker(threshold: 60)
        _ = tracker.feed(deltaX: 30, deltaY: 40, phase: .began)
        #expect(tracker.feed(deltaX: 40, deltaY: 60, phase: .changed) == nil)
        #expect(!tracker.isHorizontal)
        // Momentum after the fingers lift is ignored.
        #expect(tracker.feed(deltaX: 200, deltaY: 0, phase: .momentum) == nil)
    }

    @MainActor @Test func modelStepsAndReordersLocally() {
        let model = SidebarModel()
        model.profiles = [SidebarProfile(id: a, name: "Default"), SidebarProfile(id: b, name: "Work"), SidebarProfile(id: c, name: "Play")]
        model.activeProfileID = a
        #expect(model.stepProfile(by: 1))
        #expect(model.activeProfileID == b)
        #expect(!model.stepProfile(by: 5) || model.activeProfileID == c)
        model.send(.reorderProfile(a, index: 3))
        #expect(model.profiles.map(\.id) == [b, c, a])
    }

    @Test func emojiIconsAreDetected() {
        #expect(SidebarProfile(id: a, name: "x", icon: "🚀").iconIsEmoji)
        #expect(!SidebarProfile(id: a, name: "x", icon: "briefcase.fill").iconIsEmoji)
    }
}
