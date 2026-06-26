import CoreGraphics
import Testing
@testable import CmuxCanvasUI

@MainActor
@Suite("Canvas space pan")
struct CanvasSpacePanTests {
    private let behavior = CanvasSpacePanBehavior()

    @Test func dragMovesViewportAsIfGrabbingCanvas() {
        let origin = behavior.clipOrigin(
            startClipOrigin: CGPoint(x: 100, y: 200),
            startWindowPoint: CGPoint(x: 40, y: 50),
            currentWindowPoint: CGPoint(x: 70, y: 90),
            magnification: 1
        )

        #expect(origin.x == 70)
        #expect(origin.y == 240)
    }

    @Test func dragDeltaScalesWithMagnification() {
        let origin = behavior.clipOrigin(
            startClipOrigin: CGPoint(x: 100, y: 200),
            startWindowPoint: CGPoint(x: 40, y: 50),
            currentWindowPoint: CGPoint(x: 70, y: 90),
            magnification: 0.5
        )

        #expect(origin.x == 40)
        #expect(origin.y == 280)
    }

    @Test func spaceKeyDoesNotArmPanWhilePaneOwnsKeyboardFocus() {
        #expect(!behavior.shouldConsumeSpaceKey(
            isPointerInsideCanvas: true,
            canInterceptKeyboardTarget: false,
            isPanning: false
        ))
    }

    @Test func spaceKeyCanArmPanWhenCanvasOwnsKeyboardFocus() {
        #expect(behavior.shouldConsumeSpaceKey(
            isPointerInsideCanvas: true,
            canInterceptKeyboardTarget: true,
            isPanning: false
        ))
    }

    @Test func activePanConsumesSpaceKeyUntilGestureEnds() {
        #expect(behavior.shouldConsumeSpaceKey(
            isPointerInsideCanvas: false,
            canInterceptKeyboardTarget: false,
            isPanning: true
        ))
    }

    @Test func spaceKeyRepeatPreservesInitialConsumptionDecision() {
        #expect(behavior.shouldConsumeSpaceKeyRepeat(
            didConsumeSpaceKey: true,
            isPanning: false
        ))
        #expect(!behavior.shouldConsumeSpaceKeyRepeat(
            didConsumeSpaceKey: false,
            isPanning: false
        ))
    }

    @Test func spaceKeyDoesNotArmPanWhileTextOrControlOwnsKeyboardFocus() {
        #expect(!behavior.shouldConsumeSpaceKey(
            isPointerInsideCanvas: true,
            canInterceptKeyboardTarget: false,
            isPanning: false
        ))
    }

    @Test func spaceKeyDoesNotArmPanWhileForeignViewOwnsKeyboardFocus() {
        #expect(!behavior.shouldConsumeSpaceKey(
            isPointerInsideCanvas: true,
            canInterceptKeyboardTarget: false,
            isPanning: false
        ))
    }

    @Test func panBeginsOnlyWhenConsumedSpaceIsStillPhysicallyHeld() {
        #expect(behavior.canBeginPan(
            didConsumeSpaceKey: true,
            isPhysicalSpaceKeyPressed: true,
            isPointerInsideCanvas: true
        ))
        #expect(!behavior.canBeginPan(
            didConsumeSpaceKey: true,
            isPhysicalSpaceKeyPressed: false,
            isPointerInsideCanvas: true
        ))
    }

    @Test func panDoesNotBeginFromSpaceDeliveredToPane() {
        #expect(!behavior.canBeginPan(
            didConsumeSpaceKey: false,
            isPhysicalSpaceKeyPressed: true,
            isPointerInsideCanvas: true
        ))
    }

    @Test func hiddenCanvasDoesNotHandleSpacePanEvents() {
        #expect(behavior.shouldHandleEvents(isWorkspaceVisible: true))
        #expect(!behavior.shouldHandleEvents(isWorkspaceVisible: false))
    }
}
