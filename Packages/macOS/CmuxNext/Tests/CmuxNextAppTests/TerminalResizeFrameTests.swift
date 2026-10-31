import AppKit
@testable import CmuxNextDesign
import CmuxNextSignposts
@testable import CmuxNextTerminal
import CmuxNextWakeups
import GhosttyNextKit
import IOSurface
import Testing

/// p03-rendering-084 (ghostty-integration-DESIGN.md G1): a resized terminal's frame at its new size, the text
/// reflowed to the new columns, goes into the Core Animation commit that carries the size whenever the
/// renderer thread has drawn it by then; the main thread never waits for it; and no commit shows an older
/// frame after a newer one (Ghostty orders the pre-commit present and the renderer's own by one frame sequence).
///
/// The resize is the app's: a container's `layout()` sets the terminal's frame in AppKit's display cycle, which
/// runs inside Core Animation's commit (a divider drag, a window resize, a split). A run-loop observer added
/// there runs after that commit; the presenter's pass must still run before it.
///
/// Runs only with a GhosttyNextKit pin whose present never waits (`GHOSTTY_PRESENT_NEVER_WAITS`).
/// skip-owner: PL-ghostty; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: TerminalHostFramePresenter.presentNeverWaits))
struct TerminalResizeFrameTests {
    /// The written text: lines that fill the first grid's columns exactly, so any narrower grid wraps each
    /// into two rows. A frame drawn from the old grid's cells shows `lines` rows of text; the reflowed one
    /// shows twice as many.
    static let lines = 6

    /// A display-cycle resize whose display work outlasts the renderer's draw (a STRESS layout): the
    /// presenter's pass runs after that work and before the commit, Ghostty's present is called in it, and
    /// the commit carries the frame at the new size with the text reflowed (not the old frame clipped or
    /// padded, not a new-size frame of the old grid's text). A narrowing drag never shows a wider (older)
    /// frame after a narrower one.
    @Test func aDisplayCycleResizesCommitCarriesTheReflowedFrame() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        var misses: [String] = []
        var widths: [Int] = []
        for step in 1...6 {
            let shipped = await fixture.resizeInDisplayCycle(width: 600 - CGFloat(step) * 20, displayWorkMicroseconds: 30_000)
            misses += shipped.misses.map { "step \(step): \($0)" }
            if let width = shipped.width { widths.append(width) }
        }
        #expect(misses.isEmpty, "\(misses)")
        #expect(widths == widths.sorted(by: >), "an older, wider frame came back after a newer one: \(widths)")
    }

    /// The present never waits on the main thread (the waiting one cost up to 4 ms per drag frame): display-
    /// cycle resizes in fast turns, whose frames are not drawn by the commit, still get a pass before each
    /// commit, and each pass stays under a millisecond and a half.
    @Test func thePresentNeverWaitsForAFrameNotDrawnYet() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        var passesBeforeCommit: [Bool] = []
        for step in 1...8 {
            let before = fixture.presenter.passes
            _ = await fixture.resizeInDisplayCycle(width: 600 - CGFloat(step) * 20, displayWorkMicroseconds: 0)
            passesBeforeCommit.append(fixture.presenter.passes > before)
        }
        #expect(passesBeforeCommit.allSatisfy { $0 }, "a resize's pass ran after its commit: \(passesBeforeCommit)")
        #expect(fixture.presenter.longestPass < .microseconds(1_500), "a present pass took \(fixture.presenter.longestPass)")
    }

    /// The window's content: its `layout()` gives the terminal the width asked for, as a pane's layout does.
    final class ResizingContainer: NSView {
        var terminalWidth: CGFloat = 600
        weak var terminal: NSView?

        override func layout() {
            super.layout()
            terminal?.frame = NSRect(x: 0, y: 0, width: terminalWidth, height: 300)
        }
    }

    /// The rest of the display cycle's work, after every layout (a STRESS window): its display sleeps.
    final class DisplayWork: NSView {
        var microseconds: UInt32 = 0
        /// Runs at the start of each display, before the work.
        var onDisplay: (() -> Void)?

        nonisolated override var wantsUpdateLayer: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func updateLayer() {
            onDisplay?()
            if microseconds > 0 { usleep(microseconds) } // test: the display cycle's own work, the condition under test
        }
    }

    struct Fixture {
        let io = ScriptedTerminalIO()
        let session: TerminalSession
        let window: NSWindow
        let container: ResizingContainer
        let work: DisplayWork
        let presenter: TerminalHostFramePresenter
        let previousPresenter: TerminalHostFramePresenter?
        let drew: Bool

        init() async throws {
            _ = NSApplication.shared
            GhosttyRuntime.startedForTests()
            drew = WindowDrawPolicy.drawsWhenOccluded
            WindowDrawPolicy.drawsWhenOccluded = true
            previousPresenter = GhosttyRuntime.shared.hostFramePresenter
            presenter = try #require(TerminalHostFramePresenter.makeIfPresentNeverWaits())
            GhosttyRuntime.shared.hostFramePresenter = presenter
            session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
            try #require(session.surfaceView.surface != nil, "libghostty created no surface")
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 320), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            container = ResizingContainer(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
            window.contentView = container
            container.terminal = session.view
            container.addSubview(session.view)
            // After the terminal, so its display comes after the terminal's layout.
            work = DisplayWork(frame: NSRect(x: 620, y: 0, width: 8, height: 8))
            container.addSubview(work)
            window.orderFrontRegardless()
            container.layoutSubtreeIfNeeded() // sync-layout: the first grid, before the text written to fill it
            let surface = try #require(session.surfaceView.surface)
            let first = ghostty_surface_size(surface)
            try #require(first.columns >= 20 && Int(first.rows) >= 2 * TerminalResizeFrameTests.lines, "first grid \(first.columns)x\(first.rows)")
            // The cursor hidden, then lines that fill the columns exactly and end without a newline.
            let line = String(repeating: "x", count: Int(first.columns))
            let text = "\u{1b}[?25l" + Array(repeating: line, count: TerminalResizeFrameTests.lines).joined(separator: "\r\n")
            io.send(.output(Data(text.utf8)))
            let cellHeight = Int(first.cell_height_px)
            await Self.shown(in: session.surfaceView) { frame in
                (TerminalResizeFrameTests.textRows(of: frame, cellHeight: cellHeight) ?? 0) >= Double(TerminalResizeFrameTests.lines - 1)
            }
        }

        func close() {
            io.finish()
            window.close()
            GhosttyRuntime.shared.hostFramePresenter = previousPresenter
            WindowDrawPolicy.drawsWhenOccluded = drew
        }

        /// Resizes the terminal to `width` through the next display cycle's layout, with that cycle's display
        /// work taking `displayWorkMicroseconds` after it. Returns the shown frame's pixel width after the
        /// commit and what that commit got wrong.
        func resizeInDisplayCycle(width: CGFloat, displayWorkMicroseconds: UInt32) async -> (width: Int?, misses: [String]) {
            let countersBefore = session.diagnostics.renderCounters
            let passesBefore = presenter.passes
            let surfaceBefore = session.surfaceView.bounds.width
            var atDisplay: (surfaceWidth: CGFloat, passes: Int)?
            work.microseconds = displayWorkMicroseconds
            work.onDisplay = { [session, presenter] in atDisplay = (session.surfaceView.bounds.width, presenter.passes) }
            container.terminalWidth = width
            container.needsLayout = true
            work.needsDisplay = true
            let outcome = await withCheckedContinuation { (done: CheckedContinuation<CommitBoundary.Outcome, Never>) in
                CommitBoundary().after { done.resume(returning: $0) }
            }
            work.onDisplay = nil
            var misses: [String] = []
            if outcome == .missed { misses.append("the boundary missed the commit") }
            guard let atDisplay else { return (nil, misses + ["the display cycle did not display in that commit"]) }
            let surfaceWidth = session.surfaceView.bounds.width
            if surfaceWidth == surfaceBefore { misses.append("the display cycle did not resize the terminal (surface \(surfaceWidth))") }
            if atDisplay.surfaceWidth != surfaceWidth { misses.append("the display work ran before the resize (surface \(atDisplay.surfaceWidth), then \(surfaceWidth))") }
            if presenter.passes == passesBefore { misses.append("no presenter pass before the commit") }
            if displayWorkMicroseconds > 0, presenter.passes == atDisplay.passes { misses.append("the presenter's pass ran before the display work, not ahead of the commit") }
            let countersAfter = session.diagnostics.renderCounters
            if let before = countersBefore, let after = countersAfter {
                if after.hostPresentCalls <= before.hostPresentCalls { misses.append("Ghostty's present was not called before the commit") }
                if displayWorkMicroseconds > 0, after.hostFreshPresents <= before.hostFreshPresents {
                    misses.append("no fresh frame was presented in the commit")
                }
            } else {
                misses.append("no render counters")
            }
            let wanted = session.surfaceView.convertToBacking(session.surfaceView.bounds.size)
            guard let frame = session.surfaceView.presentedFrame else { return (nil, misses + ["the commit carried no frame"]) }
            if frame.width != Int(wanted.width) || frame.height != Int(wanted.height) {
                misses.append("commit carried \(frame.width)x\(frame.height), size \(Int(wanted.width))x\(Int(wanted.height))")
            } else if displayWorkMicroseconds > 0, let surface = session.surfaceView.surface {
                // The frame is at the new size: its text must be the new grid's, every line wrapped once.
                let cellHeight = Int(ghostty_surface_size(surface).cell_height_px)
                let rows = TerminalResizeFrameTests.textRows(of: frame, cellHeight: cellHeight) ?? 0
                if rows < Double(2 * TerminalResizeFrameTests.lines) - 1.5 {
                    misses.append("stale text: the frame's text spans \(String(format: "%.1f", rows)) rows, reflowed it spans \(2 * TerminalResizeFrameTests.lines)")
                }
            }
            return (frame.width, misses)
        }

        /// Waits until the surface shows a frame that `accept`s, read after each commit: every frame Ghostty
        /// presents lands on the main thread in a run-loop pass of its own, which ends with a commit. No clock.
        static func shown(in view: TerminalSurfaceView, _ accept: (IOSurface) -> Bool) async {
            while !(view.presentedFrame.map(accept) ?? false) {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    CommitBoundary().after { _ in done.resume() }
                }
            }
        }
    }

    /// How many cell rows the frame's text spans, from its first to its last pixel row that differs from the
    /// background (the top-left corner), in `cellHeight` pixels: nil for a format it cannot read or no text.
    static func textRows(of surface: IOSurface, cellHeight: Int) -> Double? {
        guard surface.bytesPerElement == 4, surface.width > 0, surface.height > 0, cellHeight > 0 else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let corner = (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        var first: Int?, last: Int?
        for y in 0..<surface.height {
            let row = bytes + y * surface.bytesPerRow
            var inked = 0
            for x in stride(from: 0, to: surface.width, by: 2) {
                let pixel = row + x * 4
                if abs(Int(pixel[0]) - corner.0) + abs(Int(pixel[1]) - corner.1) + abs(Int(pixel[2]) - corner.2) > 90 { inked += 1 }
            }
            guard inked >= 2 else { continue }
            if first == nil { first = y }
            last = y
        }
        guard let first, let last else { return nil }
        return Double(last - first + 1) / Double(cellHeight)
    }
}
