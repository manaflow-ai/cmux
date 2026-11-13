// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import CmuxNextComputerUse
import CmuxNextDaemon
import CmuxNextActions
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import os
@testable import CmuxNextMacScreen
import Testing
import VideoToolbox

/// The live preview of an agent's Computer Use: which surface a session belongs to, when the
/// preview shows, what the person's gestures do, where it docks, and what the presenter shows.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ComputerUsePreviewTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    // MARK: Surfaces and rules

    @Test func sessionKeysNameTheirTerminalOrChat() {
        #expect(ComputerUsePreviewSurface(session: "terminal:term_abc:4242") == .terminal(resource: "term_abc"))
        #expect(ComputerUsePreviewSurface(session: "acp-session-7") == .chat(session: "acp-session-7"))
        #expect(ComputerUsePreviewSurface(session: "unbound-91") == nil)
        #expect(ComputerUsePreviewSurface(session: "") == nil)
        #expect(ComputerUsePreviewSurface(session: "terminal::4242") == nil)
        #expect(ComputerUsePreviewSurface(session: "terminal:term_abc") == nil)
    }

    @Test func theFocusedSurfacesNewestLiveSessionShows() {
        let rules = ComputerUsePreviewRules(lingers: 15)
        let candidates = [
            ComputerUsePreviewCandidate(session: "terminal:term_a:1", lastAction: now.addingTimeInterval(-5)),
            ComputerUsePreviewCandidate(session: "terminal:term_a:2", lastAction: now.addingTimeInterval(-1)),
            ComputerUsePreviewCandidate(session: "terminal:term_b:3", lastAction: now),
            ComputerUsePreviewCandidate(session: "chat-1", lastAction: now, stopped: true),
        ]
        #expect(rules.session(for: .terminal(resource: "term_a"), among: candidates, enabled: true, now: now)?.session == "terminal:term_a:2")
        // Off: nothing shows, whatever acts.
        #expect(rules.session(for: .terminal(resource: "term_a"), among: candidates, enabled: false, now: now) == nil)
        // Nothing focused, a stopped session, another surface's session.
        #expect(rules.session(for: nil, among: candidates, enabled: true, now: now) == nil)
        #expect(rules.session(for: .chat(session: "chat-1"), among: candidates, enabled: true, now: now) == nil)
        #expect(rules.session(for: .chat(session: "chat-2"), among: candidates, enabled: true, now: now) == nil)
        // An agent that has not acted for `lingers` no longer shows.
        let later = now.addingTimeInterval(16)
        #expect(rules.session(for: .terminal(resource: "term_a"), among: candidates, enabled: true, now: later) == nil)
    }

    @Test func aPreviewLingersUntilFifteenSecondsAfterItsLastAction() {
        let rules = ComputerUsePreviewRules()
        let candidate = ComputerUsePreviewCandidate(session: "chat-1", lastAction: now)
        #expect(rules.lingersUntil(candidate, now: now.addingTimeInterval(3)) == now.addingTimeInterval(15))
        #expect(rules.lingersUntil(candidate, now: now.addingTimeInterval(15)) == nil)
    }

    @Test func gesturesMoveBetweenCardExpandedAndHidden() {
        #expect(ComputerUsePreviewPresentation.card.after(.expand) == .expanded)
        #expect(ComputerUsePreviewPresentation.expanded.after(.collapse) == .card)
        #expect(ComputerUsePreviewPresentation.expanded.after(.hide) == .hidden)
        #expect(ComputerUsePreviewPresentation.card.after(.hide) == .hidden)
        #expect(ComputerUsePreviewPresentation.hidden.after(.show) == .card)
        // A hidden preview does not expand from a stray click; a card does not collapse further.
        #expect(ComputerUsePreviewPresentation.hidden.after(.expand) == .hidden)
        #expect(ComputerUsePreviewPresentation.card.after(.collapse) == .card)
    }

    // MARK: Layout

    @Test func theThumbnailDocksTopRightAtTheReferenceInsets() {
        let layout = ComputerUsePreviewLayout(aspect: 16.0 / 10.0)
        let frame = layout.thumbnailFrame(in: CGSize(width: 1000, height: 700))
        #expect(frame.size == CGSize(width: 200, height: 125))
        // 20.5 pt from the right, 24.5 pt below the top (origin bottom left, rounded to points).
        #expect(frame.maxX == (1000 - 20.5).rounded())
        #expect(frame.origin.y == (700 - 24.5 - 125).rounded())
        // A portrait window keeps 200 pt on its long side.
        #expect(ComputerUsePreviewLayout(aspect: 0.5).thumbnailSize(available: 1000) == CGSize(width: 100, height: 200))
    }

    @Test func theThumbnailShrinksWithTheSurfaceAndKeepsItsSizeRange() {
        #expect(ComputerUsePreviewLayout(aspect: 2).thumbnailSize(available: 141) == CGSize(width: 100, height: 50))
        #expect(ComputerUsePreviewLayout(longSide: 900, aspect: 1).thumbnailSize(available: 2000) == CGSize(width: 400, height: 400))
        #expect(ComputerUsePreviewLayout(longSide: 10, aspect: 1).thumbnailSize(available: 2000) == CGSize(width: 120, height: 120))
        // A broken aspect falls back to 16:10 instead of a zero or infinite size.
        #expect(ComputerUsePreviewLayout(aspect: .nan).thumbnailSize(available: 1000) == CGSize(width: 200, height: 125))
    }

    @Test func aDragSnapsToTheNearestCorner() {
        let size = CGSize(width: 800, height: 600)
        #expect(ComputerUsePreviewLayout.Corner.nearest(to: CGPoint(x: 700, y: 500), in: size) == .topRight)
        #expect(ComputerUsePreviewLayout.Corner.nearest(to: CGPoint(x: 100, y: 500), in: size) == .topLeft)
        #expect(ComputerUsePreviewLayout.Corner.nearest(to: CGPoint(x: 700, y: 100), in: size) == .bottomRight)
        #expect(ComputerUsePreviewLayout.Corner.nearest(to: CGPoint(x: 100, y: 100), in: size) == .bottomLeft)
        let frame = ComputerUsePreviewLayout(corner: .bottomLeft, aspect: 2).thumbnailFrame(in: size)
        #expect(frame.origin == CGPoint(x: CGFloat(20.5).rounded(), y: CGFloat(20.5).rounded()))
    }

    @Test func theExpandedViewKeepsTheAspectWithinItsShare() {
        let size = ComputerUsePreviewLayout(aspect: 2).expandedSize(in: CGSize(width: 1000, height: 1000))
        #expect(size == CGSize(width: 860, height: 430))
        let tall = ComputerUsePreviewLayout(aspect: 0.5).expandedSize(in: CGSize(width: 1000, height: 1000))
        #expect(tall == CGSize(width: 430, height: 860))
    }

    /// The picture size asked of cmux Remote: the expanded view's is the wire's largest; the card's
    /// twice its pixel long side, 512 to 800.
    @Test func theStreamSizeFollowsThePresentation() {
        #expect(ComputerUsePreviewPresenter.streamLongSide(expanded: true, cardPoints: 200, backingScale: 2) == 1600)
        #expect(ComputerUsePreviewPresenter.streamLongSide(expanded: false, cardPoints: 200, backingScale: 2) == 800)
        #expect(ComputerUsePreviewPresenter.streamLongSide(expanded: false, cardPoints: 160, backingScale: 2) == 640)
        #expect(ComputerUsePreviewPresenter.streamLongSide(expanded: false, cardPoints: 120, backingScale: 1) == 512)
        #expect(ComputerUsePreviewPresenter.streamLongSide(expanded: false, cardPoints: 400, backingScale: 2) == 800)
    }

    /// No empty card: a card or the expanded view shows only once a picture came, and never while
    /// the window is private; the chip a person hid it to shows without one.
    @Test func nothingShowsBeforeAPicture() throws {
        var picture = ComputerUsePreviewPicture()
        #expect(picture.hidesOverlay(presentation: .card) && picture.hidesOverlay(presentation: .expanded))
        #expect(!picture.hidesOverlay(presentation: .hidden), "the chip shows without a picture")
        picture.apply(.status(ComputerUsePreviewStatus(state: .noWindow)))
        #expect(picture.hidesOverlay(presentation: .card), "no_window before a picture stays hidden")
        picture.apply(.pictured)
        #expect(!picture.hidesOverlay(presentation: .card))
        picture.apply(.status(ComputerUsePreviewStatus(state: .blocked)))
        #expect(picture.hidesOverlay(presentation: .card) && picture.hidesOverlay(presentation: .hidden))
        picture.apply(.status(ComputerUsePreviewStatus(state: .streaming)))
        #expect(picture.hidesOverlay(presentation: .card), "allowed again, but no new picture yet")
    }

    /// Stills of window A, then cmux Remote streams window B and no frame comes (minimized, an
    /// encoder stall): A's still must not stay up under B, and the overlay hides (round-5 follow-up
    /// review of ae25158: A's still survived the switch and nothing cleared it if A was denied).
    @Test func anotherWindowTakesTheOldStillAway() throws {
        var picture = ComputerUsePreviewPicture()
        let stream = ComputerUsePreviewStream(session: "chat-1", longSide: 800) { picture.apply($0) }
        stream.receive(.status(ComputerUsePreviewStatus(state: .still, window: 1)))
        let sequence = try #require(stream.stills.put(jpeg: try jpeg(width: 40, height: 20)))
        stream.receive(.stillReady(sequence: sequence))
        #expect(picture.still != nil && !picture.hidesOverlay(presentation: .card), "A's still shows")
        stream.receive(.status(ComputerUsePreviewStatus(state: .streaming, window: 2)))
        #expect(picture.still == nil, "no still of A under B")
        #expect(picture.hidesOverlay(presentation: .card) && picture.hidesOverlay(presentation: .expanded))
        // The same for video: A's frame, then B streams with no frame yet.
        let encoded = try encodeOneFrame(width: 320, height: 200)
        let format = try #require(ComputerUsePreviewStream.format(sps: encoded.sps, pps: encoded.pps))
        let sample = try #require(ComputerUsePreviewStream.sample(encoded.avcc, format: format, microseconds: 1))
        stream.receive(.sample(sample))
        #expect(!picture.hidesOverlay(presentation: .card), "B's first frame shows")
        stream.receive(.status(ComputerUsePreviewStatus(state: .still, window: 3)))
        #expect(picture.hidesOverlay(presentation: .card), "window C before its first still: nothing shows")
    }

    /// Only plain Escape closes the expanded view; a chord with Command, Option, Control or Shift
    /// goes on to the surface.
    @Test func onlyPlainEscapeClosesTheExpandedView() {
        #expect(ComputerUsePreviewPresenter.closesExpandedView(keyCode: 53, modifiers: []))
        #expect(ComputerUsePreviewPresenter.closesExpandedView(keyCode: 53, modifiers: [.function, .capsLock]))
        for chord: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            #expect(!ComputerUsePreviewPresenter.closesExpandedView(keyCode: 53, modifiers: chord))
        }
        #expect(!ComputerUsePreviewPresenter.closesExpandedView(keyCode: 36, modifiers: []))
    }

    /// Escape closes the expanded view only while the keyboard is in the preview's own surface:
    /// typed into another field of the window (a tab being renamed), it belongs to that field.
    @Test func escapeBelongsToTheFieldThatHasTheKeyboard() {
        let surface = NSView(), inner = NSView(), elsewhere = NSTextField()
        surface.addSubview(inner)
        #expect(ComputerUsePreviewPresenter.keyboardIsInSurface(surface, surface: surface))
        #expect(ComputerUsePreviewPresenter.keyboardIsInSurface(inner, surface: surface))
        #expect(!ComputerUsePreviewPresenter.keyboardIsInSurface(elsewhere, surface: surface))
        #expect(!ComputerUsePreviewPresenter.keyboardIsInSurface(nil, surface: surface))
        #expect(!ComputerUsePreviewPresenter.keyboardIsInSurface(inner, surface: nil))
    }

    /// A still shows in whichever view holds the picture: the card, or the expanded view while
    /// expanded (round-4 review: the expanded view was an empty box on the stills path).
    @Test func aStillShowsInTheViewThatHoldsThePicture() async throws {
        let overlay = ComputerUsePreviewOverlay(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        overlay.present(.card)
        let source = try #require(CGImageSourceCreateWithData(try jpeg(width: 40, height: 20) as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        overlay.show(still: image)
        #expect(overlay.showsStill == (thumbnail: true, expanded: false))
        overlay.present(.expanded)
        #expect(overlay.showsStill == (thumbnail: false, expanded: true))
        #expect(overlay.thumbnail.isHidden, "the card is hidden while the expanded view shows the picture")
        // Collapsing: the expanded view keeps the picture and takes no click while it fades out,
        // then hands the picture to the card.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            overlay.collapseFinished = { done.resume() }
            overlay.present(.card)
            #expect(overlay.showsStill == (thumbnail: false, expanded: true), "the picture stays in the fading view")
            #expect(overlay.expandedIsClosing && overlay.thumbnail.isHidden)
        }
        overlay.collapseFinished = nil
        #expect(overlay.showsStill == (thumbnail: true, expanded: false))
        #expect(!overlay.thumbnail.isHidden && !overlay.expandedIsClosing)
        overlay.show(still: nil)
        #expect(overlay.showsStill == (thumbnail: false, expanded: false))
    }

    /// Hiding the preview and showing it again opens a new channel with an empty picture: the
    /// still from before is gone and nothing shows until the new channel sends one (round-6 review:
    /// a still of a window since denied came back on show).
    @Test func aPictureNeverOutlivesItsChannel() throws {
        let host = PreviewHost()
        let remote = CmuxRemoteService(connection: { nil })
        let presenter = ComputerUsePreviewPresenter(remote: remote, registry: ActionRegistry(), host: host)
        var opened: [ComputerUsePreviewStream] = []
        presenter.openChannel = { session, side, onEvent in
            let stream = ComputerUsePreviewStream(session: session, longSide: side, onEvent: onEvent)
            opened.append(stream)
            return stream
        }
        let millis = Date().timeIntervalSince1970 * 1000
        let data = try JSONSerialization.data(withJSONObject: ["event": "computer-use-activity",
                                                               "sessions": [["session": "chat-1", "label": "Codex", "last_action_ms": millis]]])
        remote.computerUse.take(activityEvent: try JSONDecoder().decode(JSONValue.self, from: data))
        presenter.update()
        let first = try #require(opened.last)
        first.receive(.status(ComputerUsePreviewStatus(state: .still, window: 1)))
        let sequence = try #require(first.stills.put(jpeg: try jpeg(width: 40, height: 20)))
        first.receive(.stillReady(sequence: sequence))
        let overlay = try #require(presenter.shownOverlay)
        #expect(!overlay.isHidden && overlay.showsStill.thumbnail, "the still shows")
        presenter.set(session: "chat-1", shown: false)
        presenter.set(session: "chat-1", shown: true)
        #expect(opened.count == 2, "showing again opens a new channel")
        #expect(overlay.isHidden, "nothing shows before the new channel sends a picture")
        #expect(overlay.showsStill == (thumbnail: false, expanded: false))
    }
}
