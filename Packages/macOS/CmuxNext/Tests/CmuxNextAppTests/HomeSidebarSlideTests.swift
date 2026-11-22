import CmuxNextDesign
import CoreGraphics
import Testing
@testable import CmuxNextApp

/// The Chief sidebar's slide (the header avatar's click): one spring owns
/// the motion and places both the transcript and the sidebar, as the
/// details panel of the Messages app does. Before, two AppKit animator
/// frames ran side by side and a reopen mid-close first snapped the sidebar
/// back off screen, so the panel jumped and the transcript snapped.
@Suite struct HomeSidebarSlideTests {
    static let bounds = CGRect(x: 0, y: 0, width: 900, height: 600)
    static let width: CGFloat = 280
    static let policy = MotionPolicy(speed: .fast, reduceMotion: false)
    static let frame = 1.0 / 60.0

    static func frames(_ slide: HomeSidebarSlide) -> (transcript: CGRect, sidebar: CGRect) {
        slide.frames(in: bounds, sidebarWidth: width, scale: 2)
    }

    /// Runs frames until the spring stops; every frame keeps the transcript's
    /// right edge on the sidebar's left edge (no gap, no overlap).
    @discardableResult
    static func settle(_ slide: inout HomeSidebarSlide, maxFrames: Int = 600) -> Int {
        var count = 0
        while slide.advance(frame, policy: policy) {
            count += 1
            let f = frames(slide)
            #expect(f.transcript.maxX == f.sidebar.minX, "the transcript and the sidebar split apart in frame \(count)")
            #expect(f.sidebar.minX >= bounds.maxX - width, "the sidebar passed its open edge in frame \(count)")
            #expect(f.sidebar.minX <= bounds.maxX, "the sidebar passed its closed edge in frame \(count)")
            if count > maxFrames { break }
        }
        return count
    }

    @Test func closedTheTranscriptFillsThePaneAndTheSidebarIsOffScreen() {
        let slide = HomeSidebarSlide()
        #expect(!slide.isOpen)
        #expect(!slide.isVisible)
        #expect(Self.frames(slide).transcript == Self.bounds)
        #expect(Self.frames(slide).sidebar.minX == Self.bounds.maxX)
    }

    @Test func openSlidesInOverSeveralFramesAndEndsWithTheTranscriptNarrowed() {
        var slide = HomeSidebarSlide()
        slide.setOpen(true, animated: true)
        #expect(slide.isOpen)
        #expect(slide.isVisible, "the sidebar must be on screen from the first frame of the slide")
        // The first frame still shows the closed layout: the slide starts where the panel is.
        #expect(Self.frames(slide).transcript.width == Self.bounds.width)
        let count = Self.settle(&slide)
        #expect(count > 5, "the open ran in \(count) frames: it snapped")
        #expect(count < 120, "the open never settled")
        #expect(Self.frames(slide).transcript.width == Self.bounds.width - Self.width)
        #expect(Self.frames(slide).sidebar.minX == Self.bounds.maxX - Self.width)
    }

    @Test func closeIsTheReverseAndHidesTheSidebarAtTheEnd() {
        var slide = HomeSidebarSlide()
        slide.setOpen(true, animated: false)
        slide.setOpen(false, animated: true)
        #expect(!slide.isOpen)
        #expect(slide.isVisible, "the sidebar must stay on screen while it slides out")
        let count = Self.settle(&slide)
        #expect(count > 5)
        #expect(!slide.isVisible)
        #expect(Self.frames(slide).transcript == Self.bounds)
    }

    @Test func aToggleMidFlightReversesFromWhereThePanelIsWithoutAJump() {
        var slide = HomeSidebarSlide()
        slide.setOpen(true, animated: true)
        for _ in 0..<5 { _ = slide.advance(Self.frame, policy: Self.policy) }
        let before = Self.frames(slide)
        #expect(before.sidebar.minX < Self.bounds.maxX && before.sidebar.minX > Self.bounds.maxX - Self.width)
        slide.setOpen(false, animated: true)
        // The reverse starts from the panel's place on screen.
        #expect(Self.frames(slide) == before, "the reverse jumped")
        // One more frame moves the panel only a little: it keeps its momentum, then turns.
        _ = slide.advance(Self.frame, policy: Self.policy)
        #expect(abs(Self.frames(slide).sidebar.minX - before.sidebar.minX) < Self.width / 4)
        Self.settle(&slide)
        #expect(!slide.isVisible)
        #expect(Self.frames(slide).transcript.width == Self.bounds.width)
    }

    @Test func rapidTogglesEndInTheLastRequestedState() {
        var slide = HomeSidebarSlide()
        for clicks in 1...7 {
            slide.setOpen(!slide.isOpen, animated: true)
            for _ in 0..<(clicks % 3 + 1) { _ = slide.advance(Self.frame, policy: Self.policy) }
            let f = Self.frames(slide)
            #expect(f.transcript.maxX == f.sidebar.minX)
        }
        // Seven clicks: open.
        #expect(slide.isOpen)
        Self.settle(&slide)
        #expect(slide.isVisible)
        #expect(Self.frames(slide).transcript.width == Self.bounds.width - Self.width)
    }

    @Test func withoutMovementTheSidebarSnaps() {
        var slide = HomeSidebarSlide()
        slide.setOpen(true, animated: false)
        #expect(!slide.isMoving)
        #expect(Self.frames(slide).transcript.width == Self.bounds.width - Self.width)
        slide.setOpen(false, animated: false)
        #expect(!slide.isVisible)
        #expect(Self.frames(slide).transcript == Self.bounds)
    }

    @Test func theSharedEdgeIsOnAPixel() {
        var slide = HomeSidebarSlide()
        slide.setOpen(true, animated: true)
        for _ in 0..<40 {
            _ = slide.advance(Self.frame, policy: Self.policy)
            let edge = Self.frames(slide).sidebar.minX * 2
            #expect(edge == edge.rounded(), "the edge \(edge / 2) is between pixels: it shimmers")
        }
    }
}
