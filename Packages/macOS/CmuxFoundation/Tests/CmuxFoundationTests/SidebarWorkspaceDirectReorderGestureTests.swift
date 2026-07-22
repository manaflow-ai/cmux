import CoreGraphics
import Testing
@testable import CmuxFoundation

@Suite struct SidebarWorkspaceDirectReorderGestureTests {
    private let windowBounds = CGRect(x: 100, y: 100, width: 400, height: 600)
    private let origin = CGPoint(x: 120, y: 160)

    private func makeGesture() -> SidebarWorkspaceDirectReorderGesture {
        SidebarWorkspaceDirectReorderGesture(
            origin: origin,
            windowBounds: windowBounds,
            dragThreshold: 4,
            systemHandoffMargin: 24
        )
    }

    @Test func releaseBeforeDragThresholdRemainsAClick() {
        var gesture = makeGesture()

        #expect(gesture.drag(to: CGPoint(x: 122, y: 162)) == .none)
        #expect(gesture.release(at: CGPoint(x: 122, y: 162)) == .click)
        #expect(gesture.phase == .finished)
    }

    @Test func thresholdStartsOneLocalReorderLifecycle() {
        var gesture = makeGesture()
        let first = CGPoint(x: 126, y: 160)
        let second = CGPoint(x: 126, y: 190)

        #expect(gesture.drag(to: first) == .beginReorder(at: first))
        #expect(gesture.drag(to: second) == .updateReorder(at: second))
        #expect(gesture.release(at: second) == .commitReorder(at: second))
        #expect(gesture.release(at: second) == .none)
    }

    @Test func pointerOutsideSidebarStillUpdatesInsideWindow() {
        var gesture = makeGesture()
        _ = gesture.drag(to: CGPoint(x: 126, y: 160))
        let contentAreaPoint = CGPoint(x: 450, y: 500)

        #expect(gesture.drag(to: contentAreaPoint) == .updateReorder(at: contentAreaPoint))
        #expect(gesture.release(at: contentAreaPoint) == .commitReorder(at: contentAreaPoint))
    }

    @Test func systemHandoffRequiresLeavingWindowMargin() {
        var gesture = makeGesture()
        _ = gesture.drag(to: CGPoint(x: 126, y: 160))
        let overshoot = CGPoint(x: windowBounds.maxX + 12, y: 500)
        let beyondMargin = CGPoint(x: windowBounds.maxX + 25, y: 500)

        #expect(gesture.drag(to: overshoot) == .updateReorder(at: overshoot))
        #expect(gesture.drag(to: beyondMargin) == .handoffToSystemDrag(at: beyondMargin))
        #expect(gesture.release(at: beyondMargin) == .none)
    }

    @Test func cancellationEndsWithoutCommit() {
        var gesture = makeGesture()
        _ = gesture.drag(to: CGPoint(x: 126, y: 160))

        #expect(gesture.cancel() == .cancelReorder)
        #expect(gesture.release(at: CGPoint(x: 126, y: 160)) == .none)
    }
}
