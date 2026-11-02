import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// REOPEN-F1 (reopen film, cmux24, 5 of 5 cycles, 2026-11-02): after Cmd-Q (keep sessions) and reopen, the
/// window's first frame showed the first terminal with its last content, but the other visible terminal pane
/// was empty for 125-200 ms. The app makes at most one new surface per display frame
/// (`ContentPresentationScheduler`), and a terminal's saved frame showed only on its surface, so every pane after
/// the first waited for its own frame. Each visible terminal must show its last content in the same turn
/// (the window's first frame), and the launch's number is the last pane to show, not the first
/// (`terminal.launch_frame_shown` counted only the first and hid it).
@MainActor @Suite(.serialized, .closesItsWindows) struct ReopenEveryTerminalFirstFrameTests {
    static let keys = ["tab_reopen_left", "tab_reopen_right"]

    private static func tree() -> DaemonTree {
        let panes = keys.enumerated().map { index, key in
            PaneSnapshot(id: PaneID(rawValue: UInt64(index + 1)),
                         tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(index + 1)), tabResourceID: ResourceID(rawValue: key), title: "~")])
        }
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5,
                                      a: .leaf(PaneID(rawValue: 1)), b: .leaf(PaneID(rawValue: 2)))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: panes)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"reopen-every-terminal","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// Views under `view` that show a saved frame (a layer whose contents is a bitmap), shown ones only.
    private static func savedFrames(in view: NSView) -> Int {
        guard !view.isHidden else { return 0 }
        let own = (view.layer?.contents).map { CFGetTypeID($0 as CFTypeRef) == CGImage.typeID } == true ? 1 : 0
        return view.subviews.reduce(own) { $0 + savedFrames(in: $1) }
    }

    @Test(.timeLimit(.minutes(2)))
    func everyVisibleTerminalShowsItsLastFrameInTheSameTurnAndTheLaunchNumberIsTheLastPane() async throws {
        _ = NSApplication.shared
        let state = FileManager.default.temporaryDirectory.appending(path: "reopen-every-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        var environment = AppEnvironment.current([:])
        environment.sidebarSnapshotFile = SidebarSnapshotFile(url: state.appending(path: "sidebar-snapshot.json"))
        // The key the panes find their frames by (`PaneController.launchFrames`).
        let stateKey = try #require(environment.sidebarSnapshotFile?.url.deletingLastPathComponent())
        let services = AppServices(environment: environment)
        let store = services.daemon.store
        store.connectionState = .connected(try Self.connected())
        store.apply(snapshot: Self.tree())
        let models = try #require(store.workspaces.first?.screens.first?.panes)
        try #require(models.count == 2)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let windowState = WindowState(record: record)
        let panes = models.map { PaneController(pane: $0, daemon: services.daemon, layoutPaneID: LayoutPaneID($0.id), services: services, state: windowState) }
        defer { for pane in panes { pane.teardown() } }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        window.contentView = root
        for (index, pane) in panes.enumerated() {
            pane.view.frame = NSRect(x: CGFloat(index) * 450, y: 0, width: 450, height: 400)
            root.addSubview(pane.view)
            pane.view.layoutSubtreeIfNeeded()
        }
        window.orderFrontRegardless()
        let tabKeys = try panes.map { pane in try #require(pane.pane.tabs.first?.id) }
        #expect(tabKeys == Self.keys, "the tabs' keys are their resource ids")

        // The last quit saved each visible terminal's frame at its surface's size in its pane.
        var images: [String: NSImage] = [:]
        for (pane, key) in zip(panes, tabKeys) {
            let host = pane.view.contentHost.bounds.size
            try #require(host.width > 0 && host.height > 0, "the pane's content is not laid out")
            let surface = NSSize(width: TerminalHostView.surfaceWidth(hostWidth: host.width), height: host.height)
            images[key] = TerminalLaunchFrameTests.frame(surface, scale: window.backingScaleFactor)
        }
        let directory = stateKey.appending(path: "terminal-launch-frames", directoryHint: .isDirectory)
        await TerminalLaunchFrames(directory: directory).save(images: images)
        // This launch read them before its window (the app's `main`).
        let frames = TerminalLaunchFrames.beside(stateKey)
        await frames.prefetch(on: BackgroundWork(label: "test.reopen-every-terminal"))?.value

        // The reopened window lays its panes out: both come on screen in one pass, one new surface per frame.
        for pane in panes { pane.setPresence(.visible) }
        // Same turn, before any display frame: what the window's first frame commits.
        for (pane, key) in zip(panes, tabKeys) {
            #expect(Self.savedFrames(in: pane.view.contentHost) == 1,
                    "\(key): a visible terminal shows no last content in the window's first frame (it waits for its surface)")
        }

        // The launch number: every visible terminal apart, and the last of them.
        // (debug.timings' JSON value: read through its accessors, the type is the settings module's.)
        let report = DebugTimings.handle([:])
        var shown: [Double] = []
        for key in tabKeys {
            guard let ms = report["launch_terminals"]?[key]?["frame_shown_ms"]?.doubleValue else {
                Issue.record("\(key): debug.timings has no launch_terminals row with frame_shown_ms for this terminal")
                continue
            }
            shown.append(ms)
        }
        #expect(shown.count == 2)
        #expect(report["launch_terminals_frame_shown_max_ms"]?.doubleValue == shown.max(),
                "the launch number is the last terminal to show its frame, never the first")

        // The waiting pane's surface comes on a later frame (what the scheduler's next frame runs) and takes the
        // frame over: one frame, never two or none.
        let waiting = panes[1]
        waiting.showSelected()
        #expect(waiting.view.hostsContent, "the second pane's surface never came")
        #expect(Self.savedFrames(in: waiting.view.contentHost) == 1, "the surface did not take the last frame over (none or two shown)")
    }
}
