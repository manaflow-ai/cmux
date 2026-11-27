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

    /// Leo (2026-11-22): "why do things move when i scroll around". A card the grid already
    /// built stays built while the grid moves: releasing it mid-fling tore its view down, and
    /// scrolling back built it again from nothing in a scroll frame (a blank, then a layout).
    /// Far cards are released once the grid rests.
    @Test func aMovingGridReleasesNoCard() {
        let residency = Self.residency()
        #expect(residency.slot("t0").built, "the first card is on screen, so it is built")
        residency.setScrolling(true)
        // Far past the release band (4 screens): a long fling.
        residency.scrolled(to: 6_000)
        #expect(residency.slot("t0").built, "a fling released a built card mid-scroll")
        residency.scrolled(to: 6_400)
        #expect(residency.slot("t0").built, "a fling released a built card mid-scroll")
    }

    @Test func aScrollFromCodeReleasesNoCard() {
        let residency = Self.residency()
        residency.scrolled(to: 6_000)
        #expect(residency.slot("t0").built, "a scroll from code released a built card while moving")
    }

    @Test func aScrollFromCodeBuildsNothingAhead() {
        let residency = Self.residency()
        residency.scrolled(to: 40)
        #expect(residency.nextToBuild() == nil)
    }
}
#endif
