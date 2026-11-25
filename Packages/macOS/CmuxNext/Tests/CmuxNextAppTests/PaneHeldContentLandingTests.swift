import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTerminalGeometry
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S3a (D1), the release of a spring's held content: a pane whose content keeps the larger of its
/// start and final size through a split, close or zoom spring (the provider's `holdsContentInMotion`, true for agent
/// panes; the host's injected rule for a host made without a provider). A landing frame that only moves the host (its
/// size came to rest a frame before its origin) sets the held content to its rest size in that frame, and nothing laid
/// the content out before it heard the spring land (`PaneHostView.releaseHeldContent`): a terminal in it let its
/// surface hold go from its stale host, took its start size again and sent its start grid, and the next layout pass
/// sent the final grid once more. The pane's content (`PaneContentView` with a real `TerminalSession`) lays out at its
/// rest size before it hears the landing: no grid after the final one the spring's start sent, and the surface never
/// takes its start size again.
///
/// The host is driven frame by frame as the screen presents it (`ScreenContentView.applyPresentation`): the rest
/// offset, then the frame (laid out when its size changed), and the spring flag set on its first frame and cleared on
/// the frame it lands at. The hold is injected (`PaneHostView.init(holdsContentInMotion:)`), as the provider's is.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneHeldContentLandingTests {
    /// One presented frame: the rest offset, then the frame, laid out when its size changed.
    static func present(_ host: PaneHostView, at placed: CGRect, rest: CGRect) {
        let offset = CGVector(dx: rest.minX - placed.minX, dy: rest.minY - placed.minY)
        if host.restOffset != offset { host.restOffset = offset }
        if host.frame.size != placed.size {
            host.frame = placed
            host.layoutSubtreeIfNeeded()
        } else if host.frame.origin != placed.origin {
            host.frame = placed
        }
    }

    @Test func aLandingFrameThatOnlyMovesTheHostSendsNoSecondGrid() async throws {
        _ = NSApplication.shared
        _ = GhosttyRuntime.shared
        let reveal = LaunchReveal()
        reveal.markAllReady()
        let io = GridRecordingTerminalIO()
        let session = TerminalSession(io: io)
        let content = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("terminal"), title: "zsh")]), reveal: reveal)
        content.show(session.view)
        let host = PaneHostView(pane: "p1", content: content, holdsContentInMotion: { true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let screen = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = screen
        defer {
            session.close()
            io.finish()
            window.closeAfterTest()
        }
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        host.applyShape(padding: 8, cornerRadius: 10)
        screen.addSubview(host)
        screen.layoutSubtreeIfNeeded()
        let surface = session.surfaceView
        try #require(surface.surface != nil, "libghostty created no surface")
        try #require(surface.isShown, "the terminal is not shown in its pane")
        @MainActor func grids() async -> [TerminalGridSize] {
            surface.bridge.takeUnretainedValue().input.focusGained()
            return await io.gridsUntilMarker()
        }
        // The first layout's grid is not the spring's.
        _ = await grids()
        let start = (size: surface.frame.size, grid: surface.fittedGrid)
        let log = KeyboardResizeOneGridReportTests.SizeLog(surface)

        // The spring's first frame: the rest it heads for and the flag; the content hears its final size once.
        let rest = CGRect(x: 100, y: 0, width: 500, height: 800)
        host.restSize = rest.size
        host.restOffset = CGVector(dx: rest.minX - host.frame.minX, dy: 0)
        host.isOnLayoutSpring = true
        host.announceRest()
        let atStart = await grids()
        // Its near edge moves, its far edge stays: the content holds its rest size from the first frame (Leo
        // 2026-11-05: "the main pane waits for the right pane to shift before it shifts. Like, why are you waiting?"),
        // pinned to that edge.
        for x in [20.0, 50, 80] as [CGFloat] {
            Self.present(host, at: CGRect(x: x, y: 0, width: 600 - x, height: 800), rest: rest)
            try #require(host.content.frame.size.width <= rest.width,
                         "the content waits at its start size on a spring frame (\(host.content.frame.size), rest \(rest.size))")
        }
        // Its size comes to rest a frame before its origin does...
        Self.present(host, at: rest.offsetBy(dx: -1, dy: 0), rest: rest)
        try #require(host.content.frame.size == host.contentRect.size,
                     "the content is not at its rest size before the landing (\(host.content.frame.size) in \(host.contentRect.size))")
        // ...and the frame it lands at only moves it.
        Self.present(host, at: rest, rest: rest)
        host.isOnLayoutSpring = false
        screen.layoutSubtreeIfNeeded()

        let final = try #require(surface.fittedGrid, "the terminal fits no grid")
        let atLanding = await grids()
        let startGrid = start.grid.map { "\($0)" } ?? "none"
        #expect(final != start.grid, "the spring did not change the terminal's grid (\(final))")
        #expect(atStart == [final], "the spring's start asked the PTY for \(atStart), not the final grid \(final)")
        #expect(atLanding.isEmpty, "after the final grid \(final) at the start, the landing asked the PTY for \(atLanding) (start grid \(startGrid))")
        #expect(!log.sizes.contains(start.size), "the surface took its start size \(start.size) again after the start: \(log.sizes)")
        #expect(host.content.frame.size == host.contentRect.size, "the content is not at its rest size: \(host.content.frame.size) in \(host.contentRect.size)")
        let terminalHost = session.view
        #expect(surface.frame.size == terminalHost.surfaceSize(forHostSize: terminalHost.bounds.size),
                "the surface rests at \(surface.frame.size) in a \(terminalHost.bounds.size) host")
    }
}
