import Testing
@testable import CmuxNextSidebar

/// The room dots at the bottom of the sidebar: visibility, stepping (swipe,
/// next/previous), drag reorder, and the swipe recognizer.
@Suite struct ProfileBarTests {
    private let a = ProfileKey("default"), b = ProfileKey("prof_b"), c = ProfileKey("prof_c")

    @Test func dotsStayCenteredAndThePlusTrailsThem() {
        #expect(ProfileBarLogic.slotXs(count: 2, slot: 10, width: 100) == [40, 50, 60])
        #expect(ProfileBarLogic.slotXs(count: 3, slot: 10, width: 100) == [35, 45, 55, 65])
    }

    @Test func hiddenWithOneRoom() {
        #expect(!ProfileBarLogic.isVisible(profileCount: 0))
        #expect(!ProfileBarLogic.isVisible(profileCount: 1))
        #expect(ProfileBarLogic.isVisible(profileCount: 2))
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
