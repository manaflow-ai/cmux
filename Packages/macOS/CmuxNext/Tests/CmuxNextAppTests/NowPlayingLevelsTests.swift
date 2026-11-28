import AppKit
@testable import CmuxNextSidebar
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// The Now Playing card's level bars: they sway only while a track plays and motion is allowed, as
/// endless render-server loops (no app timer), and rest still otherwise. The controls' look and
/// centering: `NowPlayingControlsCenteringTests`.
@MainActor @Suite(.serialized, .closesItsWindows) struct NowPlayingLevelsTests {
    static let labels = SidebarNowPlaying.Labels(play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track")

    static func track(playing: Bool) -> SidebarNowPlaying {
        SidebarNowPlaying(title: "Weightless", artist: "Marconi Union", isPlaying: playing, position: 60, duration: 480,
                          positionDate: Date(), canPrevious: true, canNext: true, labels: labels)
    }

    final class Harness {
        let card: SidebarNowPlayingCardView
        let window: NSWindow
        init() {
            _ = NSApplication.shared
            card = SidebarNowPlayingCardView(frame: NSRect(x: 0, y: 0, width: 216,
                                                           height: SidebarNowPlayingCardView.height(for: NowPlayingLevelsTests.track(playing: true))))
            window = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = card
            window.orderFrontRegardless()
        }
        func close() { window.close() }
        /// The bars' running loops.
        var loops: [CAAnimation] {
            (card.levels.layer?.sublayers ?? []).compactMap { $0.animation(forKey: SidebarNowPlayingLevels.levelsKey) }
        }
        func show(playing: Bool) {
            card.configure(NowPlayingLevelsTests.track(playing: playing))
            card.isHidden = false
            card.layoutSubtreeIfNeeded()
        }
    }

    @Test func theBarsSwayOnlyWhileItPlays() throws {
        let h = Harness()
        defer { h.close() }
        h.card.levels.reduceMotionOverride = false
        h.show(playing: true)
        #expect(!h.card.levels.frame.isEmpty && h.card.bounds.contains(h.card.levels.frame), "the bars are not on the card")
        #expect(!h.card.levels.frame.intersects(h.card.titleLabel.frame), "the title runs under the bars")
        let loops = h.loops
        #expect(loops.count == 3, "\(loops.count) of 3 bars move while the track plays")
        #expect(loops.allSatisfy { $0.repeatCount == .infinity }, "a bar stops on its own")
        #expect(Set(loops.map(\.duration)).count == 3, "bars that share a period move in lockstep")
        h.show(playing: false)
        #expect(h.loops.isEmpty, "the bars move while the track is paused")
        let heights = (h.card.levels.layer?.sublayers ?? []).map(\.bounds.height)
        let expected = SidebarNowPlayingLevels.rest.map { $0 * h.card.levels.bounds.height }
        #expect(zip(heights, expected).allSatisfy { abs($0 - $1) < 0.5 }, "paused bars are at \(heights), not at rest \(expected)")
    }

    @Test func theBarsRestUnderReduceMotion() {
        let h = Harness()
        defer { h.close() }
        h.card.levels.reduceMotionOverride = true
        h.show(playing: true)
        #expect(h.loops.isEmpty, "under Reduce Motion the bars still move")
        h.card.levels.reduceMotionOverride = false
        #expect(h.loops.count == 3, "allowing motion again leaves the bars still")
        h.card.isHidden = true
        h.card.layoutSubtreeIfNeeded()
        h.card.levels.needsLayout = true
        h.card.levels.layoutSubtreeIfNeeded()
        #expect(h.loops.isEmpty, "a hidden card keeps its bars moving")
    }

    /// Turning Reduce Motion on mid-track stills the bars at once, and off starts them again.
    @Test func theBarsFollowAReduceMotionChangeMidTrack() {
        let h = Harness()
        defer {
            h.close()
            Motion.reduceMotionOverride = nil
        }
        Motion.reduceMotionOverride = false
        h.show(playing: true)
        #expect(h.loops.count == 3, "the bars do not move while motion is allowed")
        Motion.reduceMotionOverride = true
        #expect(h.loops.isEmpty, "turning Reduce Motion on mid-track left the bars moving")
        Motion.reduceMotionOverride = false
        #expect(h.loops.count == 3, "turning Reduce Motion off mid-track left the bars still")
    }

    /// Previous, Play or Pause and Next are centered on the card, so Play keeps its place for every source.
    @Test func theControlsAreCenteredOnTheCard() throws {
        let h = Harness()
        defer { h.close() }
        h.show(playing: true)
        let play = h.card.playPauseButton
        #expect(play.accessibilityLabel() == "Pause" && play.icon == .mediaPause)
        let group = h.card.previousButton.frame.union(h.card.nextButton.frame)
        #expect(abs(group.midX - h.card.bounds.midX) <= 0.5, "the controls \(group) are not centered on the card \(h.card.bounds)")
        #expect(abs(play.frame.midX - h.card.bounds.midX) <= 0.5, "Play or Pause \(play.frame) is not at the card's center")
        h.show(playing: false)
        #expect(play.accessibilityLabel() == "Play" && play.icon == .mediaPlay)
    }

    /// Play or Pause draws the new glyph when the track plays or pauses, with no layout pass: its
    /// frame does not change, so AppKit lays it out no more, and the old glyph stayed until something
    /// else did.
    @Test func playOrPauseDrawsTheNewGlyphAtOnce() throws {
        let h = Harness()
        defer { h.close() }
        h.show(playing: true)
        let play = h.card.playPauseButton
        let pause = try #require(play.image)
        h.card.configure(NowPlayingLevelsTests.track(playing: false))
        let paused = try #require(play.image)
        #expect(paused !== pause, "Play or Pause still draws Pause after the track paused")
        #expect(paused.accessibilityDescription == "Play", "the glyph reads \(paused.accessibilityDescription ?? "nothing")")
        h.card.configure(NowPlayingLevelsTests.track(playing: true))
        #expect(play.image !== paused && play.image?.accessibilityDescription == "Pause", "Play or Pause still draws Play after the track played")
    }
}
