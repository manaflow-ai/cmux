import CmuxNextBridge
import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// Leo 2026-10-13: a brand-new terminal showed a preview in its tab's hover card: a picture of
/// an empty prompt. A terminal with no output yet has no preview (the card shows its plain
/// state); once it has output, it has one.
@Suite(.closesItsWindows)
@MainActor struct EmptyTerminalPreviewTests {
    @Test func aTerminalWithNoOutputYetHasNoPreview() async throws {
        _ = NSApplication.shared
        // The runner's window may report itself occluded: draw anyway, as automation launches do.
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        defer { WindowDrawPolicy.drawsWhenOccluded = drew }
        let services = AppServices(environment: AppEnvironment.current([:]))
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), title: "~"))
        // A terminal of the cache whose screen this test writes.
        let scripted = ScriptedTerminalIO()
        let session = TerminalSession(io: scripted)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let attachment = TerminalAttachment.Target(surface: tab.surface, terminalResourceID: nil, generation: nil)
        let io = DaemonTerminalIO(target: .init(attachment: attachment, initialSize: CellSize(cols: 80, rows: 24)), resizes: ResizeCoordinator(), visible: false,
                                  endpoint: { throw CancellationError() })
        services.cache.terminals[tab.id] = TerminalEntry(validity: "test", session: session, io: io,
                                                         themeKey: TerminalThemeKey(machine: services.daemon.machineID, tab: tab),
                                                         store: services.daemon.store, surface: tab.surface)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            scripted.finish()
            window.close()
        }
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        session.view.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
        window.contentView?.addSubview(session.view)
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()

        // A new shell: its prompt under the login line, nothing else.
        scripted.send(.output(Data("Last login: Mon Oct 13 09:12:44 on ttys004\r\nyou@mac ~ % ".utf8)))
        try await Self.drawn(session)
        let size = CGSize(width: 320, height: 200)
        #expect(await services.cache.previewImage(for: tab.id, maxPixelSize: size) == nil, "a terminal with no output had a preview")

        // A command still running, with its first line out: the terminal has something to show
        // (only a finished command is reported).
        scripted.send(.output(Data("npm run dev\r\n  ready on http://localhost:3000\r\n".utf8)))
        try await Self.drawn(session, after: session.surfaceView.presentedFrame)
        #expect(await services.cache.previewImage(for: tab.id, maxPixelSize: size) != nil, "a terminal with output had no preview")
    }

    /// Waits for the terminal to present a frame other than `previous`.
    private static func drawn(_ session: TerminalSession, after previous: AnyObject? = nil) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let frame = session.surfaceView.presentedFrame, frame !== previous { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(session.surfaceView.presentedFrame != nil, "the terminal never drew")
        // The parse that frame shows is done; give a later frame a moment too.
        try await Task.sleep(for: .milliseconds(100))
    }
}
