#if os(iOS)
import CmuxMobileArtifacts
import Foundation
import Testing
import UIKit
@testable import CmuxMobileTerminal

/// Leo, 2026-11-12, on LTE: "wack reconnection state / just show the cache".
///
/// No path may store a blank page, or one from before the tab's first
/// attach, over a tab's good cached frame: a tab cooled or closed before it
/// attached, the background save, the throttled saver and the placeholder
/// swap all take their frame through `TerminalFrameKeep`.
@MainActor
@Suite(.serialized) struct TerminalFrameKeepTests {
    @MainActor
    final class Silent: TerminalSession {
        let programName = "zsh"
        let isAlternateScreen = false
        var connectionState: TerminalConnectionState = .connecting(mac: "Mac Studio")
        func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void) {}
        func send(_ bytes: Data) {}
        func resize(columns: Int, rows: Int) {}
        func stop() {}
    }

    /// A page with rows on it: light glyph-sized strokes on a dark background.
    static func cachedFrame() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 390, height: 300)).image { context in
            UIColor(white: 0.08, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 390, height: 300))
            UIColor(white: 0.9, alpha: 1).setFill()
            for column in 0..<6 { context.fill(CGRect(x: 8 + column * 9, y: 12, width: 2, height: 12)) }
        }
    }

    static func uniform(_ color: UIColor, size: CGSize = CGSize(width: 390, height: 300)) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// The reviewer's route on #41930: a tab with a good cached frame whose
    /// host goes (cooled, or closed) before it ever attached. Its page is a
    /// blank surface; the old code saved that still over the cached frame.
    @Test func aPageThatNeverAttachedNeverReplacesTheCachedFrame() {
        let model = TerminalModel(session: Silent(), artifactSource: UnavailableArtifactSource(), title: "interim-coord")
        let cached = Self.cachedFrame()
        model.restoreLastFrame(cached)
        let screen = TerminalViewController(model: model)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = screen
        window.makeKeyAndVisible()
        screen.view.layoutIfNeeded()
        defer { window.isHidden = true }

        // The scenario is real: the page has a still, and it is blank.
        let still = screen.snapshot(hidingCursor: true)
        #expect(still != nil, "the page in a window has a still")
        if let still { #expect(TerminalFrameKeep.isBlank(still)) }

        #expect(model.frameForSaving() == nil, "a page from before the first attach is never saved")
        #expect(model.frameToKeep() === cached, "the tab keeps the cached frame it had")

        // Attached, but the Mac's output not drawn yet: still nothing to save.
        model.ingest(.connection(.attached))
        #expect(model.frameForSaving() == nil)
        #expect(model.frameToKeep() === cached)

        // The card snapshot taken as the page leaves is the blank surface:
        // it never stands in for the cached frame either.
        model.captureSnapshot()
        #expect(model.frameToKeep() === cached)
    }

    /// Once the Mac's output is drawn, the cached frame goes and the live page
    /// may be kept; a blank live still still falls back to the cached frame.
    @Test func liveOutputUnlocksTheLivePageButNeverABlankOne() {
        let model = TerminalModel(session: Silent(), artifactSource: UnavailableArtifactSource(), title: "interim-coord")
        let cached = Self.cachedFrame()
        model.restoreLastFrame(cached)
        model.ingest(.connection(.attached))
        model.liveOutputDrawn()
        #expect(model.drewLiveOutput)
        #expect(model.coldFrame == nil)
        // No page in a window (no live still): the cached frame stays the one kept.
        #expect(model.frameToKeep() === cached)
    }

    /// Output drawn while not attached (transport text, a stale replay) is
    /// not the Mac's screen and unlocks nothing.
    @Test func outputBeforeTheFirstAttachUnlocksNothing() {
        let model = TerminalModel(session: Silent(), artifactSource: UnavailableArtifactSource(), title: "interim-coord")
        model.restoreLastFrame(Self.cachedFrame())
        model.liveOutputDrawn()
        #expect(!model.drewLiveOutput)
        #expect(model.coldFrame != nil)
    }

    @Test func theGateKeepsOnlyLiveFramesWithRows() {
        let rows = Self.cachedFrame()
        #expect(TerminalFrameKeep.kept(rows, drewLiveOutput: true) === rows)
        #expect(TerminalFrameKeep.kept(rows, drewLiveOutput: false) == nil, "before the first attach")
        #expect(TerminalFrameKeep.kept(Self.uniform(.black), drewLiveOutput: true) == nil, "a blank page")
        #expect(TerminalFrameKeep.kept(nil, drewLiveOutput: true) == nil)
    }

    @Test func blankMeansOneColor() {
        for color in [UIColor.black, .white, UIColor(white: 0.08, alpha: 1), .clear] {
            #expect(TerminalFrameKeep.isBlank(Self.uniform(color)), "\(color)")
        }
        #expect(TerminalFrameKeep.isBlank(UIImage()), "no pixels")
        #expect(!TerminalFrameKeep.isBlank(Self.cachedFrame()))
        // One short prompt in a corner of a phone-sized page still counts.
        let prompt = UIGraphicsImageRenderer(size: CGSize(width: 780, height: 1688)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 780, height: 1688))
            UIColor(white: 0.85, alpha: 1).setFill()
            context.fill(CGRect(x: 16, y: 40, width: 3, height: 22))
            context.fill(CGRect(x: 24, y: 52, width: 10, height: 3))
        }
        #expect(!TerminalFrameKeep.isBlank(prompt))
    }
}
#endif
