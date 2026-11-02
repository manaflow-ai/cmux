import AppKit
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextDesign
import CmuxNextSidebar
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import IOSurface
import Testing

/// SWITCH FRAMES SF-5, pre-show (lead decision on #32446, 2026-11-02): a hidden terminal's output reaches the app once a
/// second (`attach-visibility-v1`), and what waits comes one round trip after the show. A switch to it showed the older
/// screen first and the newest one a frame or more later. A switch to a hidden terminal shows the newest content in its
/// first shown frame: the pane, or the window for a workspace, keeps what it showed until the terminal drew everything
/// the daemon sent up to its `shown` marker; never the older screen, never a catch-up frame after it.
@MainActor @Suite(.serialized, .closesItsWindows) struct TerminalSwitchCatchUpTests {
    /// A daemon attach with `attach-visibility-v1`: hidden, the output waits in the daemon; shown again, it comes
    /// one round trip later, then the `shown` marker (``TerminalIOEvent/caughtUp``).
    nonisolated final class BatchingIO: TerminalIO {
        let scripted = ScriptedTerminalIO()
        private let hidden = Mutex(false)
        private let waiting = Mutex<[Data]>([])

        var events: AsyncStream<TerminalIOEvent> { scripted.events }
        func write(_ data: Data) async {}
        func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}

        /// Shown again, it would catch up (the app's ``TerminalIO`` asks before it tells the daemon).
        @MainActor var catchesUpWhenShown: Bool { hidden.withLock { $0 } }

        func send(_ event: TerminalIOEvent) { scripted.send(event) }

        func hide() { hidden.withLock { $0 = true } }

        /// The program prints while the view is hidden: the daemon keeps it.
        func printWhileHidden(_ data: Data) { waiting.withLock { $0.append(data) } }

        /// The show reached the daemon: after `roundTrip` what waited arrives, then the marker.
        func show(roundTrip: Duration) {
            hidden.withLock { $0 = false }
            let owed = waiting.withLock { waiting in
                defer { waiting = [] }
                return waiting
            }
            Task { [scripted] in
                try? await Task.sleep(for: roundTrip)
                for data in owed { scripted.send(.output(data)) }
                scripted.send(.caughtUp)
            }
        }
    }

    /// What one sample of the switch showed.
    enum Seen: Equatable, CustomStringConvertible {
        /// What showed before the switch (the outgoing tab or workspace).
        case kept
        case old, new, blank
        var description: String {
            switch self { case .kept: "kept" case .old: "old" case .new: "new" case .blank: "blank" }
        }
    }

    /// Text in the top and the bottom third of a frame.
    struct Ink: Equatable {
        var top: Bool
        var bottom: Bool
    }

    static func ink(_ surface: IOSurface?) -> Ink? {
        guard let surface, surface.bytesPerElement == 4, surface.width > 0, surface.height > 2 else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let corner = (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        func inked(_ rows: Range<Int>) -> Bool {
            var differing = 0
            for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 2) {
                for x in stride(from: 0, to: surface.width, by: 2) {
                    let pixel = bytes + y * surface.bytesPerRow + x * 4
                    if abs(Int(pixel[0]) - corner.0) + abs(Int(pixel[1]) - corner.1) + abs(Int(pixel[2]) - corner.2) > 90 {
                        differing += 1
                    }
                }
            }
            return differing > 150
        }
        let third = surface.height / 3
        return Ink(top: inked(0..<third), bottom: inked((surface.height - third)..<surface.height))
    }

    /// What `session`'s pane shows on its next display: a held frame over the surface, else the surface's frame.
    static func onScreen(_ session: TerminalSession, old: Ink) -> Seen {
        var frame = session.surfaceView.presentedFrame
        for view in session.view.subviews.reversed() where !view.isHidden && view.alphaValue > 0 {
            guard let contents = view.layer?.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { continue }
            frame = unsafeDowncast(contents as CFTypeRef, to: IOSurface.self)
            break
        }
        guard let ink = ink(frame) else { return .blank }
        if ink == old { return .old }
        if ink == Ink(top: !old.top, bottom: !old.bottom) { return .new }
        return .blank
    }

    /// Four lines of text at the top.
    static let oldScreen = Data(("\u{1b}[?25l\u{1b}[2J\u{1b}[H" + Array(repeating: String(repeating: "M", count: 30), count: 4)
        .joined(separator: "\r\n")).utf8)
    /// The screen cleared, four lines of text at the bottom.
    static let newScreen: Data = {
        let line = String(repeating: "W", count: 30)
        return Data(("\u{1b}[2J\u{1b}[999;1H\u{1b}[3A\r" + [line, line, line, line].joined(separator: "\r\n")).utf8)
    }()

    /// A terminal whose view the caller puts in a window.
    static func terminal() throws -> (BatchingIO, TerminalSession) {
        let io = BatchingIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        session.view.autoresizingMask = [.width, .height]
        return (io, session)
    }

    /// Draws `oldScreen` on the shown terminal; returns where its text is.
    static func drawOld(_ io: BatchingIO, _ session: TerminalSession) async throws -> Ink {
        session.view.layoutSubtreeIfNeeded()
        io.send(.output(oldScreen))
        let by = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < by {
            if let ink = ink(session.surfaceView.presentedFrame), ink.top != ink.bottom { return ink }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the terminal never drew its first screen")
        throw CancellationError()
    }

    /// Samples `seen` every 2 ms for 700 ms (past every bound), from the switch's own turn.
    static func samples(_ seen: () -> Seen) async throws -> [Seen] {
        var samples = [seen()]
        let until = ContinuousClock.now.advanced(by: .milliseconds(700))
        while ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(2))
            samples.append(seen())
        }
        return samples
    }

    static func check(_ samples: [Seen], _ what: String) {
        let first = samples.firstIndex { $0 != .kept }
        #expect(first != nil, "\(what): the switch never showed the terminal: \(samples)")
        guard let first else { return }
        let shown = samples[first...]
        #expect(shown.allSatisfy { $0 == .new }, "\(what): after the switch the terminal showed \(Array(shown)) (want only the newest screen)")
    }

    @Test func aTabSwitchToAHiddenTerminalShowsItsNewestOutputInItsFirstFrame() async throws {
        _ = NSApplication.shared
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("a"), title: "A")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.barOrder = .aboveToolbar
        pane.frame = window.contentLayoutRect
        window.contentView = pane
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        let (io, session) = try Self.terminal()
        defer {
            session.close()
            io.scripted.finish()
        }
        pane.show(session.view)
        pane.layoutSubtreeIfNeeded()
        let old = try await Self.drawOld(io, session)

        // Another tab takes the pane (TabContentCache.conceal: suspended, then the IO hides).
        let other = NSView()
        session.isRenderingSuspended = true
        io.hide()
        pane.show(other)
        pane.layoutSubtreeIfNeeded()
        io.printWhileHidden(Self.newScreen)
        try await Task.sleep(for: .milliseconds(100))

        // Back to the terminal: the reveal (unsuspended, then the IO shown) comes before the pane shows it.
        session.isRenderingSuspended = false
        io.show(roundTrip: .milliseconds(5))
        pane.show(session.view)
        pane.layoutSubtreeIfNeeded()
        let samples = try await Self.samples {
            let shown = pane.contentHost.subviews.filter { !$0.isHidden && $0.alphaValue > 0 }
            return shown.contains { $0 === session.view } ? Self.onScreen(session, old: old) : .kept
        }
        Self.check(samples, "tab switch")
    }

    @Test func aWorkspaceSwitchToAHiddenTerminalShowsItsNewestOutputInItsFirstFrame() async throws {
        _ = NSApplication.shared
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        func settle() { for _ in 0..<4 { root.layoutSubtreeIfNeeded() } }
        settle()
        func workspace(_ content: NSView) -> WorkspaceContentView {
            let layout = NSView()
            let view = WorkspaceContentView(layoutView: layout, bar: TabStripView(model: TabStripModel()))
            content.autoresizingMask = [.width, .height]
            layout.addSubview(content)
            return view
        }
        func show(_ view: WorkspaceContentView) {
            root.show(view)
            settle()
            if let host = view.superview { view.frame = host.bounds }
            view.layoutView.frame = view.bounds
            view.layoutView.subviews.first?.frame = view.layoutView.bounds
        }
        let (io, session) = try Self.terminal()
        defer {
            session.close()
            io.scripted.finish()
        }
        let a = workspace(session.view), b = workspace(NSView())
        show(a)
        let old = try await Self.drawOld(io, session)

        // Workspace B takes the window; A's terminal hides (suspended, then the IO hides).
        show(b)
        session.isRenderingSuspended = true
        io.hide()
        io.printWhileHidden(Self.newScreen)
        try await Task.sleep(for: .milliseconds(100))

        // Back to A: its terminal is revealed in the switch's turn (here just before the window shows A).
        session.isRenderingSuspended = false
        io.show(roundTrip: .milliseconds(5))
        root.show(a)
        let samples = try await Self.samples {
            !a.isHidden && a.alphaValue > 0 ? Self.onScreen(session, old: old) : .kept
        }
        Self.check(samples, "workspace switch")
    }
}
