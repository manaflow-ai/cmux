import AppKit
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Foundation
import Testing

/// R3a (cmux-ad, after Lawrence's P0 of 2026-10-31, "resizing terminals is broken"): a visible terminal at
/// rest has one size, grid == fit(bounds) == the PTY's == the daemon's. A real Ghostty surface in a window;
/// its IO (passed at construction) is a link to a PTY owner that applies, or never applies, the grids it is
/// sent. A mismatch counts one violation once a second check sees it; a resize the PTY applies counts none.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalSizeInvariantTests {
    final class Fixture {
        let io = LinkedTerminalIO()
        let session: TerminalSession
        let window: NSWindow
        let workspace = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

        init() {
            _ = NSApplication.shared
            _ = GhosttyRuntime.shared
            session = TerminalSession(io: io)
            window = NSWindow(contentRect: workspace.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = workspace
            session.view.frame = workspace.bounds
            workspace.addSubview(session.view)
            workspace.layoutSubtreeIfNeeded()
        }

        func close() {
            io.finish()
            window.close()
        }

        /// Returns once every grid the view sent reached the IO and the surface renders the grid the IO
        /// announced last (a focus report is the marker: the IO gets it after the grids sent before it).
        func settle() async {
            session.surfaceView.bridge.takeUnretainedValue().input.focusGained()
            await io.untilMarker()
            let until = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < until, let acked = io.link.acked, session.surfaceView.currentGrid != acked {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        /// The pane takes a new size (a divider drag, a window resize) and the layout settles.
        func resize(to size: NSSize) async {
            session.view.frame = NSRect(origin: .zero, size: size)
            workspace.layoutSubtreeIfNeeded()
            await settle()
        }

        @discardableResult
        func check(_ invariant: TerminalSizeInvariant) -> Int {
            invariant.check([(key: "terminal", session: session)], action: "test.resize")
        }
    }

    @Test func aResizeThePTYNeverAppliesCountsOneViolation() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try #require(fixture.session.surfaceView.surface != nil, "libghostty created no surface")
        await fixture.settle()
        let invariant = TerminalSizeInvariant()
        let atRest = try #require(fixture.session.sizeSample, "the shown terminal gave no size sample")
        #expect(atRest.settled && atRest.sample.holds, "the terminal was not at one size before the resize: \(atRest.sample)")
        #expect(fixture.check(invariant) + fixture.check(invariant) == 0, "a terminal at one size counted a violation")

        fixture.io.link.applies = false
        await fixture.resize(to: NSSize(width: 640, height: 420))
        let sample = try #require(fixture.session.sizeSample?.sample)
        try #require(sample.fit != nil && sample.link?.sent == sample.fit && sample.link?.acked != sample.fit,
                     "the setup did not send the PTY a grid it left unapplied: \(sample)")

        #expect(fixture.check(invariant) == 0, "the first check counted a mismatch before confirming it: \(sample)")
        #expect(fixture.check(invariant) == 1, "the confirming check did not count the mismatch: \(sample)")
        #expect(fixture.check(invariant) == 0, "the same mismatch counted again")
        #expect(invariant.violations == 1, "counted \(invariant.violations) violations for one unapplied resize")
    }

    /// A grid held for an echo that cannot come (after an attach, the link records no announcement of the
    /// attach's grid, so its first claim of that same grid waits for an echo the daemon never sends): every
    /// size agrees, but the next resize waits behind it. Two checks a settle apart count it once.
    @Test func aGridHeldForAnEchoThatNeverComesCountsOneViolation() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try #require(fixture.session.surfaceView.surface != nil, "libghostty created no surface")
        await fixture.settle()
        let invariant = TerminalSizeInvariant()

        fixture.io.link.echoDue = true
        let sample = try #require(fixture.session.sizeSample?.sample)
        try #require(sample.fit != nil && sample.grid == sample.fit && sample.link?.sent == sample.fit && sample.link?.awaitingAck == true,
                     "the setup did not hold an equal grid for an echo: \(sample)")

        #expect(fixture.check(invariant) == 0, "the first check counted a held grid before confirming it: \(sample)")
        #expect(fixture.check(invariant) == 1, "a grid held for an echo that never comes counted no violation: \(sample)")
        #expect(invariant.violations == 1)
    }

    @Test func aResizeThePTYAppliesCountsNone() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try #require(fixture.session.surfaceView.surface != nil, "libghostty created no surface")
        await fixture.settle()
        let before = try #require(fixture.session.sizeSample?.sample.fit)
        let invariant = TerminalSizeInvariant()

        await fixture.resize(to: NSSize(width: 640, height: 420))
        let sample = try #require(fixture.session.sizeSample?.sample)
        #expect(sample.fit != before, "the resize did not change the terminal's grid")
        #expect(sample.holds, "a resize the PTY applied left the sizes apart: \(sample)")
        for _ in 1...3 { fixture.check(invariant) }
        #expect(invariant.violations == 0, "a resize the PTY applied counted \(invariant.violations) violations")
    }
}

/// A ``TerminalIO`` with a link to a PTY owner: each grid it is asked for is sent, and announced back (the
/// daemon's ack, a `.resize` event) only while `link.applies` is set. Focus reports are markers.
nonisolated final class LinkedTerminalIO: TerminalIO {
    @MainActor final class Link {
        var applies = true
        /// The link expects an echo whatever it sent (a claim of the size the owner already has).
        var echoDue = false
        var sent: TerminalGridSize?
        var acked: TerminalGridSize?
    }

    let events: AsyncStream<TerminalIOEvent>
    let link: Link
    var answersTerminalQueries: Bool { false }
    private let continuation: AsyncStream<TerminalIOEvent>.Continuation
    private let markers: AsyncStream<Void>
    private let markerSink: AsyncStream<Void>.Continuation

    @MainActor init() {
        link = Link()
        (events, continuation) = AsyncStream<TerminalIOEvent>.makeStream(bufferingPolicy: .unbounded)
        (markers, markerSink) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
    }

    func finish() {
        continuation.finish()
        markerSink.finish()
    }

    func write(_ data: Data) async {}

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        let grid = TerminalGridSize(columns: cols, rows: rows)
        await MainActor.run {
            link.sent = grid
            guard link.applies else { return }
            link.acked = grid
            continuation.yield(.resize(cols: cols, rows: rows))
        }
    }

    func focusGained() async { markerSink.yield() }

    @MainActor func appliesViewGrid(reporting: Bool) -> Bool { true }

    @MainActor var linkGrids: TerminalLinkGrids? {
        TerminalLinkGrids(sent: link.sent, acked: link.acked, awaitingAck: link.echoDue || link.sent != link.acked)
    }

    /// Returns at the next marker.
    @MainActor func untilMarker() async {
        for await _ in markers { return }
    }
}
