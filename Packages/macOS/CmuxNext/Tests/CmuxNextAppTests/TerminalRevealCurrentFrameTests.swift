import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import IOSurface
import Testing

/// SWITCH FRAMES (Lawrence 2026-11-02: "changing workspaces + tabs and make sure the things change frame perfect"):
/// a terminal shown again by a workspace or tab switch shows its CURRENT content in the switch frame, not the
/// picture it showed when it was hidden. A hidden terminal keeps parsing output (an agent at work in a background
/// workspace); the frame the switch commits must already carry what it parsed.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalRevealCurrentFrameTests {
    /// Which half of `surface` holds the text: rows of solid blocks in the top half or the bottom half.
    enum Half: Equatable, CustomStringConvertible {
        case none, top, bottom, both
        var description: String { switch self { case .none: "none" case .top: "top" case .bottom: "bottom" case .both: "both" } }
    }

    static func half(_ surface: IOSurface?) -> Half {
        guard let surface, surface.bytesPerElement == 4, surface.width > 0, surface.height > 1 else { return .none }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let corner = (bytes[0], bytes[1], bytes[2])
        var top = 0, bottom = 0
        for y in stride(from: 0, to: surface.height, by: 2) {
            for x in stride(from: 0, to: surface.width, by: 2) {
                let pixel = bytes + y * surface.bytesPerRow + x * 4
                let differs = abs(Int(pixel[0]) - Int(corner.0)) + abs(Int(pixel[1]) - Int(corner.1)) + abs(Int(pixel[2]) - Int(corner.2)) > 90
                guard differs else { continue }
                if y < surface.height / 2 { top += 1 } else { bottom += 1 }
            }
        }
        switch (top > 200, bottom > 200) {
        case (true, true): return .both
        case (true, false): return .top
        case (false, true): return .bottom
        case (false, false): return .none
        }
    }

    /// What the pane's next display shows: the topmost subview layer that holds an IOSurface (a held frame over the
    /// surface), else the surface's own layer contents (as `TerminalRevealFrameTests.onScreen`).
    static func onScreen(_ session: TerminalSession) -> Half {
        for view in session.view.subviews.reversed() where !view.isHidden && view.alphaValue > 0 {
            guard let contents = view.layer?.contents else { continue }
            let object = contents as CFTypeRef
            guard CFGetTypeID(object) == IOSurfaceGetTypeID() else { continue }
            return half(unsafeDowncast(object, to: IOSurface.self))
        }
        return half(session.surfaceView.presentedFrame)
    }

    /// 8 rows of solid blocks at the top (rows 1-8) or the bottom (the last 8 rows) of a 24-row screen.
    static func screen(bottom: Bool) -> Data {
        let line = String(repeating: "\u{2588}", count: 40)
        let start = bottom ? 17 : 1
        let rows = (0..<8).map { "\u{1b}[\(start + $0);1H" + line }.joined()
        return Data(("\u{1b}[?25l\u{1b}[2J" + rows).utf8)
    }

    @Test func aTerminalShownAgainShowsWhatItParsedWhileHiddenInTheSwitchFrame() async throws {
        _ = NSApplication.shared
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            io.finish()
            window.close()
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        window.contentView = host
        session.view.frame = host.bounds
        host.addSubview(session.view)
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()
        io.send(.resize(cols: 60, rows: 24))
        io.send(.output(Self.screen(bottom: false)))
        let shownBy = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < shownBy, Self.onScreen(session) != .top {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(Self.onScreen(session) == .top, "the terminal never drew its first screen")

        // Hidden by a switch (TabContentCache.conceal): suspended and out of the window.
        session.isRenderingSuspended = true
        session.view.removeFromSuperview()
        // While hidden, the program redraws: the blocks move to the bottom. The surface parses it.
        io.send(.output(Self.screen(bottom: true)))
        let lane = try #require(session.surfaceView.lane, "the surface has no output lane")
        await lane.drained()
        try await Task.sleep(for: .milliseconds(200))

        // Shown again by a switch (TabContentCache.reveal), all in one main-actor turn as WindowController.show does.
        host.addSubview(session.view)
        session.isRenderingSuspended = false
        session.view.layoutSubtreeIfNeeded()
        // The Core Animation commit at the end of this turn is the switch frame: what the layers hold now is shown.
        let switchFrame = Self.onScreen(session)
        #expect(switchFrame == .bottom, "the switch frame showed \(switchFrame), the picture from before the terminal hid; it must show what it parsed while hidden (bottom)")

        // And it settles on the current screen (the renderer catches up): no later jump to old content.
        var later: [Half] = []
        let until = ContinuousClock.now.advanced(by: .milliseconds(400))
        while ContinuousClock.now < until {
            later.append(Self.onScreen(session))
            try await Task.sleep(for: .milliseconds(4))
        }
        #expect(later.last == .bottom, "after the reveal the pane showed \(later)")
    }

    /// SF-2 (video sw-w1-light, feat 0d19fe6: 25 of 26 warm Cmd-digit switches showed EMPTY terminal panes for 1-3
    /// refreshes): a hidden terminal's presented frame is volatile (TerminalFramePurgeability), and a purged one leaves
    /// the layer empty at the reveal until Ghostty's next frame. The switch frame must never show an empty pane: here
    /// the system's purge is made explicit (kIOSurfacePurgeableEmpty) while the terminal is hidden.
    @Test func aTerminalWhoseHiddenFrameWasPurgedIsNotEmptyInTheSwitchFrame() async throws {
        _ = NSApplication.shared
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            io.finish()
            window.close()
        }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        window.contentView = host
        session.view.frame = host.bounds
        host.addSubview(session.view)
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()
        io.send(.resize(cols: 60, rows: 24))
        io.send(.output(Self.screen(bottom: false)))
        let shownBy = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < shownBy, Self.onScreen(session) != .top {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(Self.onScreen(session) == .top, "the terminal never drew its first screen")

        // Hidden by a workspace switch (the parked workspace view is hidden in its window).
        session.view.isHidden = true
        let held = try #require(session.surfaceView.presentedFrame, "no presented frame while hidden")
        // The system takes the volatile pages (memory pressure, or the GPU's own eviction).
        _ = held.setPurgeable(.empty, oldState: nil)
        try await Task.sleep(for: .milliseconds(100))

        // Shown again by the switch, in one turn (WindowRootView.show unhides the workspace view).
        session.view.isHidden = false
        session.view.layoutSubtreeIfNeeded()
        let switchFrame = Self.onScreen(session)
        #expect(switchFrame == .top, "the switch frame showed \(switchFrame): an empty pane; it must show the terminal's content")
    }
}
