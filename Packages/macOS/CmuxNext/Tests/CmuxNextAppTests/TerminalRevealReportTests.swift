import AppKit
@testable import CmuxNextDesign
import CmuxNextSignposts
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxNextWakeupsTestSupport
import Foundation
import IOSurface
import Testing

/// Nov 4 (NIGHTLY 4178064067101, "cmux perf lead"): a shown pane stayed empty for minutes while its terminals ran,
/// then drew its text at about a third of its size. Nothing in the logs could tell a discarded frame from a scale
/// mismatch. A terminal shown again now reports its scales, the frame it kept while hidden and its font
/// (``TerminalRevealReport``), and a pane still empty 500 ms later is reported again (``TerminalBlankWatch``).
@MainActor @Suite(.serialized, .closesItsWindows, .timeLimit(.minutes(1)))
struct TerminalRevealReportTests {
    // MARK: The report

    /// A frame drawn at 1x shown by a 2x layer is the tiny-text class: the report says the scales disagree.
    @Test func aContentScaleOtherThanTheLayersIsReportedAsScalesDisagreeing() {
        var report = Self.report(content: 2, layer: 2, window: 2)
        #expect(report.scalesAgree)
        report.contentScale = 1
        #expect(!report.scalesAgree)
        #expect(report.message.contains("content_scale=1.00 layer_scale=2.00 window_scale=2.00 scales_agree=false"))
        #expect(report.fields["content_scale"] == "1.00" && report.fields["scales_agree"] == "false")
    }

    /// A terminal shown again on a display of another scale keeps its frame at the layer's old scale until Ghostty's
    /// first frame at the new scale: the layer's scale is Ghostty's and lands with that frame (ghostty-integration
    /// P12, fork 0efdef967). The kept frame shows at the scale it was drawn at, so the reveal is no scale mismatch
    /// (it was reported as one, at error level, on each such reveal). A layer still at another scale after a frame
    /// showed since the reveal is one.
    @Test func aLayerScaleThatWaitsForItsFirstFrameIsNoMismatchAtTheReveal() {
        var report = Self.report(content: 2, layer: 1, window: 2)
        #expect(report.scalesAgree, "\(report.message)")
        #expect(!report.isSuspect, "\(report.message)")
        report.framesSinceReveal = 1
        #expect(!report.scalesAgree, "\(report.message)")
    }

    /// Blank means nothing on the layer and nothing held over it; a held frame is not blank.
    @Test func blankIsNoFrameAndNoHeldFrame() {
        var report = Self.report(content: 2, layer: 2, window: 2, hasFrame: false)
        #expect(report.isBlank)
        report.holdingFrame = true
        #expect(!report.isBlank)
    }

    /// A frame Ghostty showed since the reveal (its present callback) means the pane drew: not blank, and the report
    /// says how many.
    @Test func aFrameShownSinceTheRevealIsNotBlank() {
        var report = Self.report(content: 2, layer: 2, window: 2, hasFrame: false)
        report.framesSinceReveal = 2
        #expect(!report.isBlank)
        #expect(report.message.hasSuffix(" frames_since_reveal=2"))
        #expect(report.fields["frames_since_reveal"] == "2")
    }

    // MARK: The blank check

    @Test func aPaneStillBlankAtTheLimitIsReportedOnce() async throws {
        let clock = ManualClock()
        let watch = TerminalBlankWatch(clock: clock)
        let reports = Reports()
        let blank = Self.report(content: 2, layer: 2, window: 2, hasFrame: false)
        watch.watch(probe: { blank }, onBlank: { reports.items.append($0) })
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(499))
        for _ in 0..<20 { await Task.yield() }
        #expect(reports.items.isEmpty)
        clock.advance(by: .milliseconds(1))
        for _ in 0..<50 where reports.items.isEmpty { await Task.yield() }
        #expect(reports.items == [blank])
    }

    @Test func aPaneThatDrewOrWasHiddenIsNotReported() async throws {
        let clock = ManualClock()
        let watch = TerminalBlankWatch(clock: clock)
        let reports = Reports()
        watch.watch(probe: { Self.report(content: 2, layer: 2, window: 2) }, onBlank: { reports.items.append($0) })
        try await clock.waitForSleeper()
        clock.advance(by: TerminalBlankWatch.limit)
        for _ in 0..<50 { await Task.yield() }
        #expect(reports.items.isEmpty, "a pane that drew was reported blank")

        let blank = Self.report(content: 2, layer: 2, window: 2, hasFrame: false)
        watch.watch(probe: { blank }, onBlank: { reports.items.append($0) })
        try await clock.waitForSleeper()
        watch.cancel()
        clock.advance(by: TerminalBlankWatch.limit)
        for _ in 0..<50 { await Task.yield() }
        #expect(reports.items.isEmpty, "a check cancelled by a hide still reported")
        #expect(!watch.isWatching)
    }

    /// Review of #40174 (GI LAND 2): the reveal's own report no longer calls a layer scale that waits for its first
    /// frame a mismatch, and no other report read the scales after a frame showed, so a layer scale that never landed
    /// (tiny text that stays) had no report. The check at the limit now reports it, apart from a blank pane; a pane
    /// that drew at its scale, and one with no frame since the reveal (its layer scale may still wait), report nothing.
    @Test func aLayerScaleStillWrongAfterAFrameShowedIsReportedAtTheLimit() async throws {
        let clock = ManualClock()
        let watch = TerminalBlankWatch(clock: clock)
        let blank = Reports(), mismatch = Reports()
        var stale = Self.report(content: 2, layer: 1, window: 2)
        stale.framesSinceReveal = 3
        let drew = stale
        watch.watch(probe: { drew }, onBlank: { blank.items.append($0) }, onScaleMismatch: { mismatch.items.append($0) })
        try await clock.waitForSleeper()
        clock.advance(by: TerminalBlankWatch.limit)
        for _ in 0..<50 where mismatch.items.isEmpty { await Task.yield() }
        #expect(mismatch.items == [drew], "a layer scale still wrong after 3 frames was not reported")
        #expect(blank.items.isEmpty, "a pane that drew was reported blank")

        mismatch.items.removeAll()
        let waiting = Self.report(content: 2, layer: 1, window: 2)
        watch.watch(probe: { waiting }, onBlank: { blank.items.append($0) }, onScaleMismatch: { mismatch.items.append($0) })
        try await clock.waitForSleeper()
        clock.advance(by: TerminalBlankWatch.limit)
        for _ in 0..<50 { await Task.yield() }
        #expect(mismatch.items.isEmpty && blank.items.isEmpty, "a kept frame at its own scale, no frame since the reveal, was reported")
    }

    // MARK: A real terminal shown again

    /// A real Ghostty surface hidden and shown again reports its reveal: the scales agree and the frame it kept
    /// shows. With its kept frame discarded while hidden (what memory pressure does to a volatile IOSurface), the
    /// reveal says so and shows no frame until Ghostty draws: the blank pane's first moment, now in the log.
    @Test func aTerminalShownAgainReportsItsScalesAndItsKeptFrame() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let view = fixture.session.surfaceView
        fixture.recorder.revealed.removeAll() // the window's first show is a reveal too

        fixture.session.view.isHidden = true
        fixture.session.view.isHidden = false
        let first = try #require(fixture.recorder.revealed.last, "showing the terminal again reported nothing")
        #expect(first.scalesAgree, "\(first.message)")
        #expect(first.contentScale == fixture.window.backingScaleFactor, "\(first.message)")
        #expect(first.savedFrame == .kept, "\(first.message)")
        #expect(first.hasFrame, "\(first.message)")
        #expect(first.fontPoints != nil, "\(first.message)")

        fixture.session.view.isHidden = true
        let kept = try #require(view.presentedFrame, "the hidden terminal kept no frame")
        var old: UInt32 = 0
        IOSurfaceSetPurgeable(unsafeBitCast(kept, to: IOSurfaceRef.self), IOSurface.purgeableEmpty, &old) // what memory pressure does to it
        fixture.session.view.isHidden = false
        let second = try #require(fixture.recorder.revealed.last)
        #expect(fixture.recorder.revealed.count == 2)
        #expect(second.savedFrame == .purged, "\(second.message)")
        #expect(!second.hasFrame, "a discarded frame was still on the layer: \(second.message)")
    }

    // MARK: Support

    static func report(content: CGFloat, layer: CGFloat, window: CGFloat, hasFrame: Bool = true) -> TerminalRevealReport {
        TerminalRevealReport(contentScale: content, layerScale: layer, windowScale: window, savedFrame: .kept,
                             holdingFrame: false, hasFrame: hasFrame, fontPoints: 12, fontScale: nil,
                             viewSize: CGSize(width: 600, height: 300))
    }

    @MainActor final class Reports {
        var items: [TerminalRevealReport] = []
    }

    final class Recorder: TerminalSessionDelegate {
        var revealed: [TerminalRevealReport] = []
        var blank: [TerminalRevealReport] = []
        func terminalSession(_ session: TerminalSession, revealed report: TerminalRevealReport) { revealed.append(report) }
        func terminalSession(_ session: TerminalSession, blankAfterReveal report: TerminalRevealReport) { blank.append(report) }
    }

    final class Fixture {
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        let window: NSWindow
        let recorder = Recorder()
        private let drew: Bool

        init() async throws {
            _ = NSApplication.shared
            // The runner's window may report itself occluded (an app never in front): draw anyway.
            drew = WindowDrawPolicy.drawsWhenOccluded
            WindowDrawPolicy.drawsWhenOccluded = true
            session = TerminalSession(io: io, blankClock: ManualClock())
            session.delegate = recorder
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
            window.contentView = container
            session.view.frame = container.bounds
            container.addSubview(session.view)
            window.orderFrontRegardless()
            guard session.surfaceView.surface != nil else {
                close()
                throw FixtureError.noSurface
            }
            io.send(.output(Data("reveal report\r\n".utf8)))
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline, session.surfaceView.presentedFrame == nil {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    CommitBoundary().after { _ in done.resume() }
                }
            }
            guard session.surfaceView.presentedFrame != nil else {
                close()
                throw FixtureError.noFrame
            }
        }

        func close() {
            io.finish()
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drew
        }
    }

    enum FixtureError: Error { case noSurface, noFrame }
}
