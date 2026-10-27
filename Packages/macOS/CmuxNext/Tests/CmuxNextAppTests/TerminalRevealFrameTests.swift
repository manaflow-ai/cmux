import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import IOSurface
import Testing

/// cx-6so.23: a terminal shown again (a tab closed over it, a cold workspace switched back to)
/// drew blank for 2-3 frames before its content. A revealed terminal shows its content from the
/// first frame: never an empty pane.
@MainActor @Suite(.serialized) struct TerminalRevealFrameTests {
    /// What one sample of the pane showed.
    enum Shown: Equatable, CustomStringConvertible {
        case none, blank, text
        var description: String { switch self { case .none: "none" case .blank: "blank" case .text: "text" } }
    }

    /// Whether `surface` holds text: enough pixels that differ from its corner (the background).
    static func shown(_ surface: IOSurface?) -> Shown {
        guard let surface, surface.bytesPerElement == 4, surface.width > 0, surface.height > 0 else { return .none }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let corner = (bytes[0], bytes[1], bytes[2])
        var differing = 0
        for y in stride(from: 0, to: surface.height, by: 2) {
            for x in stride(from: 0, to: surface.width, by: 2) {
                let pixel = bytes + y * surface.bytesPerRow + x * 4
                if abs(Int(pixel[0]) - Int(corner.0)) + abs(Int(pixel[1]) - Int(corner.1)) + abs(Int(pixel[2]) - Int(corner.2)) > 90 {
                    differing += 1
                }
            }
        }
        return differing > 200 ? .text : .blank
    }

    /// What the pane shows on its next display: the topmost subview whose layer holds a frame (a
    /// held frame over the surface, if any). AppKit attaches subview layers on that display pass, so
    /// the view tree, not the layer tree, is what the screen gets.
    static func onScreen(_ session: TerminalSession) -> Shown {
        for view in session.view.subviews.reversed() where !view.isHidden && view.alphaValue > 0 {
            guard let contents = view.layer?.contents else { continue }
            let object = contents as CFTypeRef
            guard CFGetTypeID(object) == IOSurfaceGetTypeID() else { continue }
            return shown(unsafeDowncast(object, to: IOSurface.self))
        }
        return shown(session.surfaceView.presentedFrame)
    }

    /// What reaches the terminal around its reveal.
    enum Resync: CaseIterable {
        /// The owner re-announces the grid it held.
        case sameGrid
        /// Another client held the geometry while this view was hidden; the claim takes it back.
        case gridChangedWhileHidden
        /// The claim re-attaches with a replay of the screen.
        case replayOnReveal
    }

    @Test(arguments: Resync.allCases)
    func aRevealedTerminalShowsItsContentFromTheFirstFrame(_ resync: Resync) async throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        // The runner's window may report itself occluded (an app never in front): draw anyway, as
        // automation launches do. Hidden and suspended surfaces still pause.
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            io.finish()
            window.close()
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        window.contentView = host
        session.view.frame = host.bounds
        host.addSubview(session.view)
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()
        let line = String(repeating: "M", count: 40)
        let screen = Data(("\u{1b}[?25l\u{1b}[2J\u{1b}[H" + Array(repeating: line, count: 8).joined(separator: "\r\n")).utf8)
        io.send(.output(screen))
        let shownBy = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < shownBy, Self.shown(session.surfaceView.presentedFrame) != .text {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(Self.shown(session.surfaceView.presentedFrame) == .text, "the terminal never drew its text")
        let grid = try #require(session.surfaceView.currentGrid)

        // Hidden: another tab took the pane (TabContentCache.conceal).
        session.isRenderingSuspended = true
        session.view.removeFromSuperview()
        if resync == .gridChangedWhileHidden { io.send(.resize(cols: 80, rows: 24)) }
        try await Task.sleep(for: .milliseconds(300))

        // Shown again (TabContentCache.reveal): back in the pane, drawing, and the owner
        // re-announces the grid it claimed again.
        host.addSubview(session.view)
        session.isRenderingSuspended = false
        io.send(.resize(cols: grid.columns, rows: grid.rows))
        var samples: [Shown] = []
        if resync == .replayOnReveal {
            // The replay swaps in a fresh surface: the pane is sampled in the turn the swap lands,
            // before any renderer frame can, so the check does not race the renderer.
            let shown = session.surfaceView
            io.send(.replay(screen))
            let swappedBy = ContinuousClock.now.advanced(by: .seconds(5))
            while session.surfaceView === shown, ContinuousClock.now < swappedBy { await Task.yield() }
            try #require(session.surfaceView !== shown, "the replay did not swap the surface")
            samples.append(Self.onScreen(session))
        }
        // Past the longest hold: the live surface takes over by then.
        let until = ContinuousClock.now.advanced(by: .milliseconds(700))
        while ContinuousClock.now < until {
            samples.append(Self.onScreen(session))
            try await Task.sleep(for: .milliseconds(4))
        }
        let first = samples.firstIndex(of: .text)
        #expect(first == 0 && !samples.contains(where: { $0 != .text }), "\(resync): after the reveal the pane showed \(samples)")
        // The live surface shows the content, not a held frame.
        let held = session.view.subviews.filter { $0 !== session.surfaceView && ($0.layer?.contents).map { CFGetTypeID($0 as CFTypeRef) == IOSurfaceGetTypeID() } == true }
        #expect(held.isEmpty, "\(resync): a held frame was still up over the live surface")
        #expect(Self.shown(session.surfaceView.presentedFrame) == .text, "\(resync): the live surface did not draw the content")
    }
}
