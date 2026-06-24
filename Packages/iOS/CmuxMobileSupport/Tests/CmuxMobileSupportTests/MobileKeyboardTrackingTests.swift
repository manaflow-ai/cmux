import CoreGraphics
import Testing
@testable import CmuxMobileSupport

@Suite struct MobileKeyboardTrackingTests {
    private let tolerance: CGFloat = 0.001

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
