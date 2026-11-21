import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxTheme
import Foundation
import Testing

/// SPLIT NEW PANE GROUND (m81, cmux-ad, Lawrence: during a split "the gap shows the page colour ... no blank or
/// stale-colour frames"). Split Up's new terminal pane showed the WINDOW colour for its first two frames (cmux21,
/// 120 Hz): its stand-in terminal's surface is made right after the key's frame (one surface per frame), and until then
/// the pane's area painted the window's color. From the key's turn, the area paints the ground the terminal will paint
/// (its own background, `appearance.surfaces.terminal`, else its theme's or the config's), and the terminal's host paints
/// that same ground when it comes in. The same holds for New Terminal Tab's stand-in in an existing pane.
@Suite(.closesItsWindows)
@MainActor struct StandInTerminalGroundTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"stand-in-terminal-ground-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Waits until the main run loop's pass has committed (the signal `AfterFrameCommit` uses).
    private static func nextCommittedPass() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              false, CFIndex.max) { _, _ in
                done.resume()
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        }
    }

    private static func rgb(_ color: CGColor?) -> [Int]? {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    /// The kit's terminal ground (`appearance.surfaces.terminal`).
    private static let terminalGround = ThemeRGB(hex: 0x00FFFF)

    @Test func aStandInTerminalsPaneShowsTheTerminalsGroundFromTheKeysFrame() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let shell = try #require(store.tab(surface: SurfaceID(rawValue: 1)))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        defer { pane.teardown() }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        window.contentView = pane.view
        window.orderFrontRegardless()
        pane.view.paneScope.setSurfaceBackgrounds(SurfaceBackgrounds(overrides: [.terminal: SurfaceBackground(color: Self.terminalGround, opacity: 1)]))
        state.selection.select(shell.id, in: pane.paneKey)
        pane.syncStripFromStore()
        pane.view.layoutSubtreeIfNeeded()
        for _ in 0..<12 where services.cache.existingTerminal(shell.id) == nil { await Self.nextCommittedPass() }
        try #require(services.cache.existingTerminal(shell.id) != nil, "the shown terminal has no view: the test no longer reaches the case")
        let windowColor = Self.rgb(pane.view.performWithTheme { Palette.surfaceBackground.cgColor })
        let ground = Self.rgb(Self.terminalGround.cgColor)
        try #require(windowColor != ground, "the window colour is the terminal's: the test cannot tell them apart")

        // The key's turn, as `PaneController.newTerminalTabNow` runs it: the stand-in in the store, then selected.
        let standIn = ProvisionalTab()
        defer { services.cache.release(standIn.id) }
        store.intend(.createTab(pane: model.handle, provisional: standIn.terminal(TerminalID.generate(), cwd: nil)),
                     transaction: ClientTransactionID.generate())
        pane.selectWhenReported(surface: standIn.surface)
        try #require(pane.view.content == nil && services.cache.existingTerminal(standIn.id) == nil,
                     "the key's turn showed a terminal: the test no longer reaches the frame before its surface")

        let waiting = Self.rgb(pane.view.contentHost.layer?.backgroundColor)
        #expect(waiting == ground, "the key's frame shows \(String(describing: waiting)) where the new terminal comes, not its ground \(String(describing: ground)) (\(String(describing: windowColor)): the window colour)")

        // Its surface comes in: the terminal's host paints that same ground, and the area its own again.
        for _ in 0..<12 where services.cache.existingTerminal(standIn.id) == nil || pane.view.content == nil { await Self.nextCommittedPass() }
        let entry = try #require(services.cache.existingTerminal(standIn.id), "no terminal for the stand-in after its key's frame")
        try #require(pane.view.content === entry.session.view)
        // The host paints once before its scope joins the pane's, and a scope does not repaint for inherited surface
        // backgrounds alone: this test's pane-level background reaches the host at its next paint. (The app sets
        // `appearance.surfaces` app-wide, where the host's first paint has it.)
        let host: TerminalHostView = entry.session.view
        host.viewDidChangeEffectiveAppearance()
        #expect(Self.rgb(host.layer?.backgroundColor) == waiting, "the terminal paints another ground than its pane showed before it")
        #expect(Self.rgb(pane.view.contentHost.layer?.backgroundColor) != ground, "the area keeps the waiting ground under the shown terminal")
    }
}
