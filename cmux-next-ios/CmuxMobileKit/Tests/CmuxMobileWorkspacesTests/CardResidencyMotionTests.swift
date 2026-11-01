import CoreGraphics
import Testing

// The tab grid is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
@testable import CmuxTabsKit

/// The grid builds off-screen cards ahead only while it rests: a scroll (a finger's, a
/// deceleration's or one from code) builds only what comes on screen, and building ahead
/// resumes once the grid is still again.
@MainActor
@Suite struct CardResidencyMotionTests {
    static func residency() -> CardResidency {
        let residency = CardResidency()
        let layout = OverviewLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34, count: 60)
        residency.update(ids: (0..<60).map { "t\($0)" }, layout: layout)
        residency.setVisible(true)
        residency.setSettled(true)
        return residency
    }

    @Test func aRestingGridBuildsAhead() {
        #expect(Self.residency().nextToBuild() != nil)
    }

    @Test func aFingerScrollBuildsNothingAhead() {
        let residency = Self.residency()
        residency.setScrolling(true)
        #expect(residency.nextToBuild() == nil)
        residency.setScrolling(false)
        #expect(residency.nextToBuild() != nil)
    }

    @Test func aScrollFromCodeBuildsNothingAhead() {
        let residency = Self.residency()
        residency.scrolled(to: 40)
        #expect(residency.nextToBuild() == nil)
    }
}
#endif
