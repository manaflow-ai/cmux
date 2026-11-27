import AppKit
@testable import CmuxNextDesign
import CmuxNextIcons
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/52939 ("why is this not centered the play stuff its not perfect"): the
/// media card's Play or Pause was a filled white tile whose 13 pt glyph sat in a 32 pt disc, and Previous and Next drew
/// a 17 pt glyph (Comfortable) in a 24 pt box. An odd difference leaves a half-point inset that the button snaps to one
/// side, so the pause bars sat off their tile's center, the glyphs left the row's center line by half a point in
/// opposite directions, and the level bars grew from the bottom of an 11 pt box. Now every control is the same light
/// glyph button with its glyph inset by whole points, all on one center line with the level bars, at every density.
@MainActor @Suite(.serialized, .closesItsWindows) struct NowPlayingControlsCenteringTests {
    /// A card showing a playing video (so Picture in Picture shows too), laid out in a 2x window at `preset`.
    static func card() -> (SidebarNowPlayingCardView, NSWindow) {
        _ = NSApplication.shared
        var track = NowPlayingLevelsTests.track(playing: true)
        track.canPictureInPicture = true
        let card = SidebarNowPlayingCardView(frame: NSRect(x: 0, y: 0, width: 260, height: SidebarNowPlayingCardView.height(for: track)))
        let window = TwoXWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = card
        card.configure(track)
        card.isHidden = false
        card.layoutSubtreeIfNeeded()
        for view in card.subviews { view.layoutSubtreeIfNeeded() }
        return (card, window)
    }

    /// Where `button` draws its glyph, in the card's coordinates.
    static func glyphRect(_ button: SidebarIconButton, in card: NSView) throws -> NSRect {
        let cell = try #require(button.cell as? NSButtonCell, "the control has no button cell")
        return card.convert(cell.imageRect(forBounds: button.bounds), from: button)
    }

    @Test(arguments: DensityPreset.allCases)
    func everyControlCentersItsGlyphOnOneCenterLine(preset: DensityPreset) throws {
        try DensityTokens.$scoped.withValue(preset.tokens) {
            let (card, window) = Self.card()
            defer { window.close() }
            let glyph = SidebarNowPlayingCardView.glyphSide
            let controls: [(String, SidebarIconButton)] = [("Previous", card.previousButton), ("Play or Pause", card.playPauseButton),
                                                          ("Next", card.nextButton), ("Picture in Picture", card.pictureInPictureButton)]
            let center = card.playPauseButton.frame.midY
            for (name, button) in controls {
                #expect(!button.isHidden && !button.frame.isEmpty, "\(preset): \(name) is not on the card")
                #expect(button.frame == card.previousButton.frame.offsetBy(dx: button.frame.minX - card.previousButton.frame.minX, dy: 0),
                        "\(preset): \(name) is \(button.frame.size), Previous \(card.previousButton.frame.size): the controls differ")
                #expect(button.frame == button.frame.integral, "\(preset): \(name) at \(button.frame) is off whole points")
                let image = try #require(button.image, "\(preset): \(name) drew no glyph")
                #expect(image.size.width == glyph, "\(preset): \(name)'s glyph is \(image.size.width) pt, the controls' \(glyph) pt")
                let drawn = try Self.glyphRect(button, in: card)
                #expect(abs(drawn.midX - button.frame.midX) < 0.01 && abs(drawn.midY - button.frame.midY) < 0.01,
                        "\(preset): \(name)'s glyph \(drawn) is off its button's center \(button.frame)")
                #expect(drawn == drawn.integral, "\(preset): \(name)'s glyph \(drawn) is off whole points")
                #expect(abs(drawn.midY - center) < 0.01, "\(preset): \(name)'s glyph center \(drawn.midY) leaves the row's \(center)")
            }
            #expect(!card.levels.frame.isEmpty, "\(preset): no level bars")
            #expect(abs(card.levels.frame.midY - center) < 0.01, "\(preset): the level bars' center \(card.levels.frame.midY) leaves the row's \(center)")
            for bar in card.levels.layer?.sublayers ?? [] {
                #expect(abs(bar.frame.midY - card.levels.bounds.midY) < 0.01, "\(preset): a level bar \(bar.frame) does not grow from the center line")
            }
            #expect(abs(card.controlsDivider.frame.midY - center) < 0.01, "\(preset): the divider leaves the row's center line")
        }
    }

    /// Play or Pause is the same light glyph as Next (the user's follow-up: it was an inverted white tile): no fill
    /// at rest, the same tint, the same box.
    @Test func playOrPauseMatchesTheOtherControls() throws {
        let (card, window) = Self.card()
        defer { window.close() }
        let play = card.playPauseButton, next = card.nextButton
        #expect(play.accessibilityLabel() == "Pause" && play.icon == .mediaPause)
        play.displayIfNeeded()
        next.displayIfNeeded()
        let fill = play.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.alphaComponent ?? 0
        #expect(fill < 0.01, "Play or Pause is filled (alpha \(fill)) while Next is not")
        #expect(play.contentTintColor != nil, "Play or Pause drew no tint")
        #expect(play.contentTintColor == next.contentTintColor, "Play or Pause is tinted \(String(describing: play.contentTintColor)), Next \(String(describing: next.contentTintColor))")
        #expect(play.frame.size == next.frame.size, "Play or Pause is \(play.frame.size), Next \(next.frame.size)")
        card.configure(NowPlayingLevelsTests.track(playing: false))
        #expect(play.accessibilityLabel() == "Play" && play.icon == .mediaPlay)
    }

    /// Every glyph size a density or Interface Size can make gets a box an even number of points larger, at every
    /// density's spacing (Spacious's `space1` is 2.5 pt).
    @Test(arguments: DensityPreset.allCases)
    func everyGlyphSizeGetsAWholePointInset(preset: DensityPreset) {
        DensityTokens.$scoped.withValue(preset.tokens) {
            for glyph in stride(from: CGFloat.iconFloor, through: 30, by: 1) {
                let side = SidebarNowPlayingCardView.controlSide(glyph: glyph)
                let inset = (side - glyph) / 2
                #expect(inset == inset.rounded() && inset >= Metrics.space1, "\(preset): a \(glyph) pt glyph gets a \(side) pt box, inset \(inset)")
            }
        }
    }
}
