import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Foundation
import Testing

/// The user, 2026-11-24: hover cards and the sidebar's split miniature showed an empty tile for hibernated tabs. A
/// hibernated (evicted) terminal has no surface to capture, and the last frame it left is volatile: memory pressure
/// purges it, a pressure eviction keeps none, and the store's bound drops the oldest. The picture taken as it is
/// evicted stays, so its card shows how it last looked.
@Suite(.closesItsWindows)
@MainActor struct HibernatedTerminalPictureTests {
    @Test func aTerminalEvictedUnderPressureKeepsItsPicture() async throws {
        let (services, tab, session, done) = try await Self.terminal(output: "npm run dev\r\n  ready on http://localhost:3000\r\n")
        defer { done() }
        let size = CGSize(width: 320, height: 200)
        try #require(await services.cache.previewImage(for: tab, maxPixelSize: size) != nil, "setup: the live terminal had no picture")

        // Hibernated under memory pressure: the surface closes with no last frame kept.
        let entry = try #require(services.cache.terminals.removeValue(forKey: tab))
        services.cache.lastFrames.evict(session, key: tab, capacity: 8, atOnce: true)
        await services.cache.lastFrames.pictureSettled(tab)
        entry.close()
        #expect(services.cache.lastFrames[tab] == nil, "setup: a pressure eviction kept a frame")
        services.cache.previews.remove(tab)  // nothing from an earlier hover either

        let image = await services.cache.previewImage(for: tab, maxPixelSize: size)
        #expect(image != nil, "a hibernated terminal's card showed an empty tile")
        #expect(await ThumbnailStats.measure(try #require(image))?.isBlank == false)

        // Closed: its picture goes with it.
        services.cache.lastFrames.remove(tab)
        #expect(await services.cache.previewImage(for: tab, maxPixelSize: size) == nil)
    }

    @Test func aNewShellsPromptStillHasNoPicture() async throws {
        let (services, tab, session, done) = try await Self.terminal(output: "Last login: Mon Oct 13 09:12:44 on ttys004\r\nyou@mac ~ % ")
        defer { done() }
        let entry = try #require(services.cache.terminals.removeValue(forKey: tab))
        services.cache.lastFrames.evict(session, key: tab, capacity: 8, atOnce: true)
        await services.cache.lastFrames.pictureSettled(tab)
        entry.close()
        #expect(services.cache.lastFrames.picture(tab) == nil, "an empty prompt was pictured (Leo 2026-10-13)")
    }

    /// A cache terminal in a window, drawn showing `output`.
    private static func terminal(output: String) async throws -> (AppServices, String, TerminalSession, () -> Void) {
        _ = NSApplication.shared
        let drew = WindowDrawPolicy.drawsWhenOccluded
        WindowDrawPolicy.drawsWhenOccluded = true
        let services = AppServices(environment: AppEnvironment.current([:]))
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), title: "~"))
        let scripted = ScriptedTerminalIO()
        let session = TerminalSession(io: scripted)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let attachment = TerminalAttachment.Target(surface: tab.surface, terminalResourceID: nil, generation: nil)
        let io = DaemonTerminalIO(target: .init(attachment: attachment, initialSize: CellSize(cols: 80, rows: 24)), resizes: ResizeCoordinator(), visible: false,
                                  endpoint: { throw CancellationError() })
        services.cache.terminals[tab.id] = TerminalEntry(validity: "test", session: session, io: io,
                                                         themeKey: TerminalThemeKey(machine: services.daemon.machineID, tab: tab),
                                                         store: services.daemon.store, surface: tab.surface)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        session.view.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
        window.contentView?.addSubview(session.view)
        window.orderFrontRegardless()
        session.view.layoutSubtreeIfNeeded()
        scripted.send(.output(Data(output.utf8)))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while session.surfaceView.presentedFrame == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(session.surfaceView.presentedFrame != nil, "the terminal never drew")
        try await Task.sleep(for: .milliseconds(150))
        return (services, tab.id, session, {
            scripted.finish()
            window.close()
            WindowDrawPolicy.drawsWhenOccluded = drew
        })
    }
}
