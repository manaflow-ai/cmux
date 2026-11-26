import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// #25568: a window's frame is saved when it settles, whichever way it changed, and the next
/// launch opens the window there. The boundary: the app's services on a real same-tree daemon,
/// the window record in the daemon's `personal` projection, and a second set of services that
/// connects to the same daemon as a relaunch does.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct WindowFrameRestoreTests {
    /// Zoom, macOS tiling and Accessibility clients (Rectangle) resize with one `setFrame`, no
    /// live resize; a resize that keeps the origin moves nothing. It must still be saved.
    @Test func aResizeWithoutLiveResizeIsSaved() async throws {
        try await Self.withDaemon { launcher in
            let services = try await Self.launch(launcher)
            let result = await Self.capture {
                let controller = try #require(services.windows.active)
                let window = try #require(controller.window)
                let (first, resized) = Self.frames()
                window.setFrame(first, display: true)
                // The frame AppKit applied (it may constrain it to the host's screen).
                let moved = window.frame
                try await Self.until({ await Self.savedFrame(services, controller.state.id) == moved },
                                     report: { await Self.report(services, controller.state.id, window) })
                // Same origin, a new size: what Zoom or a tiling shortcut does to a window at the screen's corner.
                window.setFrame(CGRect(origin: moved.origin, size: resized.size), display: true)
                let grown = window.frame
                try #require(grown.origin == moved.origin && grown.size != moved.size, "a size-only change: \(moved) -> \(grown)")
                try await Self.until({ await Self.savedFrame(services, controller.state.id) == grown },
                                     report: { await Self.report(services, controller.state.id, window) })
            }
            await Self.quit(services, endingDaemon: true)
            try result.get()
        }
    }

    /// Quit (the quit path's window flush), then a relaunch on the same daemon: the window opens
    /// at the frame it had.
    @Test func aRelaunchOpensTheWindowWhereItWas() async throws {
        try await Self.withDaemon { launcher in
            let (_, resized) = Self.frames()
            let before = try await Self.launch(launcher)
            var id = ""
            var applied = CGRect.null
            let saved = await Self.capture {
                let controller = try #require(before.windows.active)
                id = controller.state.id
                let window = try #require(controller.window)
                window.setFrame(resized, display: true)
                applied = window.frame
                await before.windows.prepareForTermination()
                let saved = await Self.savedFrame(before, id)
                let report = await Self.report(before, id, window)
                #expect(saved == applied, "\(report)")
            }
            await Self.quit(before, endingDaemon: (try? saved.get()) == nil)
            try saved.get()

            let after = try await Self.launch(launcher)
            let reopened = await Self.capture {
                let controller = try #require(after.windows.controller(for: id), "the saved window reopens")
                let window = try #require(controller.window)
                let report = await Self.report(after, id, window)
                #expect(window.frame == applied, "\(report)")
            }
            await Self.quit(after, endingDaemon: true)
            try reopened.get()
        }
    }

    /// Quit, and every saved window record is gone by the relaunch (its workspaces ended at quit, as
    /// End Everything does, so the record is pruned): no saved window can come back, and the first
    /// window of the next launch opens where the front window last was, not centered.
    @Test func aRelaunchWithNoSavedWindowLeftOpensWhereTheFrontWindowWas() async throws {
        try await Self.withDaemon { launcher in
            let (_, resized) = Self.frames()
            let before = try await Self.launch(launcher)
            var applied = CGRect.null
            let saved = await Self.capture {
                let controller = try #require(before.windows.active)
                let id = controller.state.id
                let window = try #require(controller.window)
                window.setFrame(resized, display: true)
                applied = window.frame
                try await Self.until({ await Self.savedFrame(before, id) == applied },
                                     report: { await Self.report(before, id, window) })
                // Quit's flush, then the records go as a prune of ended workspaces drops them (the app
                // saves nothing after its flush, so it cannot write them back).
                await before.windows.prepareForTermination()
                let store = try #require(before.daemon.windowState)
                try await store.update { $0.prune(liveWorkspaces: []) }
                #expect(await store.document.windows.isEmpty)
            }
            await Self.quit(before, endingDaemon: (try? saved.get()) == nil)
            try saved.get()

            let after = try await Self.launch(launcher)
            let reopened = await Self.capture {
                let controller = try #require(after.windows.active)
                let window = try #require(controller.window)
                let report = await Self.report(after, controller.state.id, window)
                #expect(window.frame == applied, "\(report)")
            }
            await Self.quit(after, endingDaemon: true)
            try reopened.get()
        }
    }

    /// cmux NEXT launch: nothing moves after the first frame. The launch window's first frame takes its
    /// frame and sidebar width from the daemon's launch snapshot (`LaunchSnapshotWindow.showSaved`,
    /// `makeController`). The daemon writes that file up to 3 s after the window record changes
    /// (`LaunchSnapshotTiming`: settle 500 ms, max delay 3 s, longer under the byte budget), so a quit
    /// soon after a move or a sidebar drag, then a relaunch on the same daemon, draws the first frame
    /// from the older geometry. Restore then adopts the live record and sets the frame and the sidebar
    /// width again (`WindowManager.adoptLaunchWindow`): the window jumps and the sidebar resizes on
    /// screen after the first frame. The window must keep the geometry it was first drawn with: when
    /// the app's connection closes (quit, force quit, crash, kill) the daemon writes the file at once,
    /// so the relaunch reads the moved geometry from it. This test keeps its connection open to read
    /// the file, so it asks for the same write (`flush-launch-snapshot`).
    @Test func aRelaunchDoesNotMoveTheLaunchWindowWhenTheLaunchSnapshotLagsTheRecord() async throws {
        try await Self.withDaemon { launcher in
            let (first, resized) = Self.frames()
            let before = try await Self.launch(launcher)
            var id = ""
            var snapshot: LaunchSnapshot?
            var relaunchSnapshot: LaunchSnapshot?
            let saved = await Self.capture {
                let controller = try #require(before.windows.active)
                id = controller.state.id
                let window = try #require(controller.window)
                // Settled geometry the daemon's launch snapshot has caught up with.
                window.setFrame(first, display: true)
                controller.sidebar.model.width = 260
                let settledFrame = window.frame
                let settledWidth = Double(controller.sidebar.model.width)
                let path = try #require(before.daemon.identity?.launchSnapshotPath, "the daemon reports no launch snapshot path")
                let session = launcher.configuration.session
                let readFile = { try Data(contentsOf: URL(fileURLWithPath: path)) }
                try await Self.until({
                    guard let data = try? readFile(),
                          let read = LaunchSnapshot.decode(data, session: session),
                          let record = read.windows?.windows.first(where: { $0.id == id }),
                          record.frame.map(Self.rect) == settledFrame, record.sidebarWidth == settledWidth else { return false }
                    snapshot = read
                    return true
                }, report: { await Self.report(before, id, window) })
                // Then the person moves the window and drags the sidebar, and quits before the daemon
                // rewrites its launch snapshot: the record has the new geometry, the snapshot the old one.
                window.setFrame(resized, display: true)
                controller.sidebar.model.width = 320
                let movedFrame = window.frame
                let movedWidth = Double(controller.sidebar.model.width)
                try #require(movedFrame != settledFrame && movedWidth != settledWidth, "fixture: the move changed nothing")
                // The quit's windows step (QuitCoordinator), then the write the app's socket close makes.
                await before.windows.prepareForTermination()
                await before.daemon.connection?.flushLaunchSnapshot()
                let record = await before.daemon.windowState?.document.windows.first { $0.id == id }
                try #require(record?.frame.map(Self.rect) == movedFrame && record?.sidebarWidth == movedWidth,
                             "fixture: the quit flush did not save the moved geometry: \(String(describing: record))")
                // What a relaunch reads (`LaunchSnapshot.readAtLaunch`): the file as the quit left it, read
                // once, with no wait for the daemon's settle.
                relaunchSnapshot = try LaunchSnapshot.decode(readFile(), session: session)
            }
            await Self.quit(before, endingDaemon: (try? saved.get()) == nil)
            try saved.get()
            _ = try #require(snapshot, "fixture: the settled geometry never reached the launch snapshot")
            let lagging = try #require(relaunchSnapshot, "the launch snapshot did not read after the quit")

            // The relaunch, in `AppDelegate`'s order: the launch snapshot applies (`DaemonService.showLaunchSnapshot`),
            // the launch window shows it, then the daemon connects and restore adopts the live record.
            _ = NSApplication.shared
            let after = AppServices(environment: AppEnvironment.current([:]))
            AppActions.bind(after)
            after.daemon.store.applyProvisional(snapshot: lagging.tree)
            after.daemon.launchSnapshotWindows = lagging.windows
            after.daemon.launchSnapshotRegistryID = lagging.tree.registryID
            after.windows.restoreWhenLoaded()
            let shown = await Self.capture {
                let controller = try #require(after.windows.controller(for: id), "fixture: the launch snapshot did not open the saved window")
                let window = try #require(controller.window)
                // The first frame on screen.
                let firstFrame = window.frame
                let firstWidth = controller.sidebar.model.width
                after.daemon.start {
                    DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
                }
                try await Self.until({ after.windows.restored && !after.windows.restoring && !after.windows.registry.isLaunching
                        && after.windows.active?.workspaceContent?.panes.isEmpty == false }, within: .seconds(90))
                try #require(after.windows.controller(for: id) === controller, "fixture: restore did not adopt the launch window")
                let report = await Self.report(after, id, window)
                #expect(window.frame == firstFrame, "the launch window moved after its first frame: \(firstFrame) -> \(window.frame); \(report)")
                #expect(controller.sidebar.model.width == firstWidth,
                        "the sidebar resized after the first frame: \(firstWidth) -> \(controller.sidebar.model.width)")
            }
            await Self.quit(after, endingDaemon: true)
            try shown.get()
        }
    }

    private static func rect(_ frame: WindowFrame) -> CGRect { CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height) }

    /// Two frames inside the main screen's visible frame, the second the first one grown at the
    /// same origin.
    private static func frames() -> (CGRect, CGRect) {
        let visible = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 875)
        let first = CGRect(x: visible.minX + 40, y: visible.minY + 40, width: min(800, visible.width - 200), height: min(500, visible.height - 200))
        let resized = CGRect(origin: first.origin, size: CGSize(width: first.width + 120, height: first.height + 80))
        return (first, resized)
    }

    /// What a failure needs: the window's frame, its record, the document's last frame and the screens.
    private static func report(_ services: AppServices, _ id: String, _ window: NSWindow) async -> String {
        let document = await services.daemon.windowState?.document
        let record = document?.windows.first { $0.id == id }
        let screens = NSScreen.screens.map { "\($0.frame) visible \($0.visibleFrame)" }
        return "window \(window.frame) record \(String(describing: record?.frame)) display \(String(describing: record?.display)) "
            + "records \(document?.windows.count ?? -1) screens \(screens)"
    }

    private static func savedFrame(_ services: AppServices, _ id: String) async -> CGRect? {
        guard let store = services.daemon.windowState else { return nil }
        return await store.document.windows.first { $0.id == id }?.frame.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }

    /// The app's services on `launcher`'s daemon, once restore finished and its window shows a pane.
    private static func launch(_ launcher: DaemonLauncher) async throws -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        do {
            // Restore finished (a frame set before it is not saved until the next save) and the
            // window shows its workspace's pane.
            try await until({ services.windows.restored && !services.windows.restoring && !services.windows.registry.isLaunching
                    && services.daemon.windowState != nil && services.windows.active?.workspaceContent?.panes.isEmpty == false },
                            within: .seconds(90))
        } catch {
            await quit(services, endingDaemon: true)
            throw error
        }
        return services
    }

    /// Ends this launch: its windows and its connection, and when `endingDaemon` the daemon with its
    /// terminals (else the next launch reconnects to it, as after Quit and Keep Sessions).
    private static func quit(_ services: AppServices, endingDaemon: Bool) async {
        for controller in services.windows.controllers { controller.window?.close() }
        guard let connection = services.daemon.connection else { return }
        // The app's connection first: on the daemon's EOF it would start a fresh daemon.
        services.daemon.shutdownConnection()
        await connection.close()
        if endingDaemon { _ = try? await connection.shutdownDaemon(endTerminals: true) }
    }

    private static func capture(_ body: () async throws -> Void) async -> Result<Void, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private static func withDaemon(_ body: (DaemonLauncher) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-frame-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-frame-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        try await body(launcher)
    }

    private static func until(_ condition: () async throws -> Bool, within timeout: Duration = .seconds(20),
                              report: () async -> String = { "" }, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(try await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let met = try await condition()
        let detail = met ? "" : await report()
        try #require(met, "timed out: \(detail)", sourceLocation: sourceLocation)
    }
}
