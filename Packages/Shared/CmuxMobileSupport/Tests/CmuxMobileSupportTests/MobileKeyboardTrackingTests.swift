import CoreGraphics
import Testing
@testable import CmuxMobileSupport

@Suite struct MobileKeyboardTrackingTests {
    private let tolerance: CGFloat = 0.001

    @Test func dockedKeyboardProducesBottomReservation() {
        let reservation = MobileKeyboardReservation(
            keyboardFrameInWindow: CGRect(x: 0, y: 500, width: 400, height: 300),
            viewFrameInWindow: CGRect(x: 0, y: 0, width: 400, height: 800)
        )

        #expect(reservation.height == 300)
    }

    @Test func floatingKeyboardDoesNotProduceBottomReservation() {
        let reservation = MobileKeyboardReservation(
            keyboardFrameInWindow: CGRect(x: 220, y: 360, width: 360, height: 180),
            viewFrameInWindow: CGRect(x: 0, y: 0, width: 800, height: 1_000)
        )

        #expect(reservation.height == 0)
    }

    @Test func floatingKeyboardStillCountsAsVisible() {
        let visibility = MobileKeyboardVisibility(
            keyboardFrameInWindow: CGRect(x: 220, y: 360, width: 360, height: 180),
            viewFrameInWindow: CGRect(x: 0, y: 0, width: 800, height: 1_000)
        )

        #expect(visibility.isVisible)
    }

    @Test func hiddenKeyboardBelowViewIsNotVisible() {
        let visibility = MobileKeyboardVisibility(
            keyboardFrameInWindow: CGRect(x: 0, y: 1_000, width: 800, height: 300),
            viewFrameInWindow: CGRect(x: 0, y: 0, width: 800, height: 1_000)
        )

        #expect(!visibility.isVisible)
    }

    @Test func keyboardExtendingBelowViewUsesVisibleBottomOverlap() {
        let reservation = MobileKeyboardReservation(
            keyboardFrameInWindow: CGRect(x: 0, y: 650, width: 400, height: 350),
            viewFrameInWindow: CGRect(x: 0, y: 100, width: 400, height: 700)
        )

        #expect(reservation.height == 150)
    }

    @Test func bottomPositionKeepsContentEndPinnedWhenKeyboardInsetGrows() {
        let snapshot = MobileScrollViewportSnapshot(
            contentOffsetY: 1_400,
            boundsHeight: 600,
            adjustedBottomInset: 0,
            contentHeight: 2_000,
            atBottomThreshold: 40
        )

        let offset = snapshot.restoredOffsetY(
            contentHeight: 2_000,
            boundsHeight: 600,
            adjustedTopInset: 0,
            adjustedBottomInset: 300
        )

        #expect(snapshot.wasAtBottom)
        #expect(offset == 1_700)
        #expect(offset + 600 - 300 == 2_000)
    }

    @Test func bottomPositionKeepsContentEndPinnedWhenViewportShrinks() {
        let snapshot = MobileScrollViewportSnapshot(
            contentOffsetY: 1_400,
            boundsHeight: 600,
            adjustedBottomInset: 0,
            contentHeight: 2_000,
            atBottomThreshold: 40
        )

        let offset = snapshot.restoredOffsetY(
            contentHeight: 2_000,
            boundsHeight: 300,
            adjustedTopInset: 0,
            adjustedBottomInset: 0
        )

        #expect(snapshot.wasAtBottom)
        #expect(offset == 1_700)
        #expect(offset + 300 == 2_000)
    }

    @Test func middlePositionPreservesVisibleBottomWhenKeyboardInsetGrows() {
        let snapshot = MobileScrollViewportSnapshot(
            contentOffsetY: 700,
            boundsHeight: 600,
            adjustedBottomInset: 0,
            contentHeight: 2_000,
            atBottomThreshold: 40
        )

        let offset = snapshot.restoredOffsetY(
            contentHeight: 2_000,
            boundsHeight: 600,
            adjustedTopInset: 0,
            adjustedBottomInset: 300
        )

        #expect(!snapshot.wasAtBottom)
        #expect(offset == 1_000)
        #expect(abs((offset + 600 - 300) - snapshot.visibleBottomY) < tolerance)
    }

    @Test func middlePositionPreservesVisibleBottomWhenViewportShrinks() {
        let snapshot = MobileScrollViewportSnapshot(
            contentOffsetY: 700,
            boundsHeight: 600,
            adjustedBottomInset: 0,
            contentHeight: 2_000,
            atBottomThreshold: 40
        )

        let offset = snapshot.restoredOffsetY(
            contentHeight: 2_000,
            boundsHeight: 300,
            adjustedTopInset: 0,
            adjustedBottomInset: 0
        )

        #expect(!snapshot.wasAtBottom)
        #expect(offset == 1_000)
        #expect(abs((offset + 300) - snapshot.visibleBottomY) < tolerance)
    }

    @Test func topPositionClipsFromTopWhenKeyboardInsetGrows() {
        let snapshot = MobileScrollViewportSnapshot(
            contentOffsetY: 0,
            boundsHeight: 600,
            adjustedBottomInset: 0,
            contentHeight: 2_000,
            atBottomThreshold: 40
        )

        let offset = snapshot.restoredOffsetY(
            contentHeight: 2_000,
            boundsHeight: 600,
            adjustedTopInset: 0,
            adjustedBottomInset: 300
        )

        #expect(!snapshot.wasAtBottom)
        #expect(offset == 300)
        #expect(abs((offset + 600 - 300) - snapshot.visibleBottomY) < tolerance)
    }

    @Test func topPositionClipsFromTopWhenViewportShrinks() {
        let snapshot = MobileScrollViewportSnapshot(
            contentOffsetY: 0,
            boundsHeight: 600,
            adjustedBottomInset: 0,
            contentHeight: 2_000,
            atBottomThreshold: 40
        )

        let offset = snapshot.restoredOffsetY(
            contentHeight: 2_000,
            boundsHeight: 300,
            adjustedTopInset: 0,
            adjustedBottomInset: 0
        )

        #expect(!snapshot.wasAtBottom)
        #expect(offset == 300)
        #expect(abs((offset + 300) - snapshot.visibleBottomY) < tolerance)
    }

    @Test func topPositionRestoresWhenKeyboardInsetShrinks() {
        let snapshot = MobileScrollViewportSnapshot(
            contentOffsetY: 300,
            boundsHeight: 600,
            adjustedBottomInset: 300,
            contentHeight: 2_000,
            atBottomThreshold: 40
        )

        let offset = snapshot.restoredOffsetY(
            contentHeight: 2_000,
            boundsHeight: 600,
            adjustedTopInset: 0,
            adjustedBottomInset: 0
        )

        #expect(offset == 0)
        #expect(abs((offset + 600) - snapshot.visibleBottomY) < tolerance)
    }
}
