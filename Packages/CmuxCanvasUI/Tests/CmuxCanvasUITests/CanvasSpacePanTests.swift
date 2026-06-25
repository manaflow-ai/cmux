import CoreGraphics
import Testing
@testable import CmuxCanvasUI

@MainActor
@Suite("Canvas space pan")
struct CanvasSpacePanTests {
    @Test func dragMovesViewportAsIfGrabbingCanvas() {
        let origin = canvasSpacePanClipOrigin(
            startClipOrigin: CGPoint(x: 100, y: 200),
            startWindowPoint: CGPoint(x: 40, y: 50),
            currentWindowPoint: CGPoint(x: 70, y: 90),
            magnification: 1
        )

        #expect(origin.x == 70)
        #expect(origin.y == 240)
    }

    @Test func dragDeltaScalesWithMagnification() {
        let origin = canvasSpacePanClipOrigin(
            startClipOrigin: CGPoint(x: 100, y: 200),
            startWindowPoint: CGPoint(x: 40, y: 50),
            currentWindowPoint: CGPoint(x: 70, y: 90),
            magnification: 0.5
        )

        #expect(origin.x == 40)
        #expect(origin.y == 280)
    }

    @Test func spaceKeyDoesNotArmPanWhilePaneOwnsKeyboardFocus() {
        #expect(!canvasSpacePanShouldConsumeSpaceKey(
            isPointerInsideCanvas: true,
            canInterceptKeyboardTarget: false,
            isPanning: false
        ))
    }

    @Test func spaceKeyCanArmPanWhenCanvasOwnsKeyboardFocus() {
        #expect(canvasSpacePanShouldConsumeSpaceKey(
            isPointerInsideCanvas: true,
            canInterceptKeyboardTarget: true,
            isPanning: false
        ))
    }

    @Test func activePanConsumesSpaceKeyUntilGestureEnds() {
        #expect(canvasSpacePanShouldConsumeSpaceKey(
            isPointerInsideCanvas: false,
            canInterceptKeyboardTarget: false,
            isPanning: true
        ))
    }

    @Test func spaceKeyRepeatPreservesInitialConsumptionDecision() {
        #expect(canvasSpacePanShouldConsumeSpaceKeyRepeat(
            didConsumeSpaceKey: true,
            isPanning: false
        ))
        #expect(!canvasSpacePanShouldConsumeSpaceKeyRepeat(
            didConsumeSpaceKey: false,
            isPanning: false
        ))
    }

    @Test func spaceKeyDoesNotArmPanWhileTextOrControlOwnsKeyboardFocus() {
        #expect(!canvasSpacePanShouldConsumeSpaceKey(
            isPointerInsideCanvas: true,
            canInterceptKeyboardTarget: false,
            isPanning: false
        ))
    }

    @Test func spaceKeyDoesNotArmPanWhileForeignViewOwnsKeyboardFocus() {
        #expect(!canvasSpacePanShouldConsumeSpaceKey(
            isPointerInsideCanvas: true,
            canInterceptKeyboardTarget: false,
            isPanning: false
        ))
    }

    @Test func panBeginsOnlyWhenConsumedSpaceIsStillPhysicallyHeld() {
        #expect(canvasSpacePanCanBegin(
            didConsumeSpaceKey: true,
            isPhysicalSpaceKeyPressed: true,
            isPointerInsideCanvas: true
        ))
        #expect(!canvasSpacePanCanBegin(
            didConsumeSpaceKey: true,
            isPhysicalSpaceKeyPressed: false,
            isPointerInsideCanvas: true
        ))
    }

    @Test func panDoesNotBeginFromSpaceDeliveredToPane() {
        #expect(!canvasSpacePanCanBegin(
            didConsumeSpaceKey: false,
            isPhysicalSpaceKeyPressed: true,
            isPointerInsideCanvas: true
        ))
    }

    @Test func hiddenCanvasDoesNotHandleSpacePanEvents() {
        #expect(canvasSpacePanShouldHandleEvents(isWorkspaceVisible: true))
        #expect(!canvasSpacePanShouldHandleEvents(isWorkspaceVisible: false))
    }
}
