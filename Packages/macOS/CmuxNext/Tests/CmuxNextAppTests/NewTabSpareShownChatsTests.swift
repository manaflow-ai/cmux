import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The launch's New Tab spare waits for the restored chat pages on screen to draw. Started beside
/// them, its page loaded in WebKit at the same time, and on a NIGHTLY relaunch where the spare went
/// first the shown chat drew at 1814 ms instead of 1094 ms (L5, cmux20, 2026-11-09). Leo,
/// 2026-11-05: "It should take a lot faster of a time to be loading, like within a few seconds."
/// The native spare stands in for the web one: both are made by the same launch warm.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct NewTabSpareShownChatsTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "shown-ws"), name: "shown", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "shown-ws"), index: 0)])
        return tree
    }

    /// A fresh pool on a window, with the native spare on, and `loading` as the shown chats not drawn yet. The body
    /// gets `paint[i]` (page i drawing) and `asked()`, how many pages the launch warm asked to wait on: the warm
    /// ran and holds the spare once it is `loading`.
    private static func withPool(loading: Int, _ body: (NewTabSparePool, NSWindow, [() -> Void], () -> Int) async throws -> Void) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let directory = FileManager.default.temporaryDirectory.appending(path: "shown-chats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"tabs":{"nativeNewTabPage":true}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: services.registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        services.settings = settings
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["shown-ws"], frame: CGRect(x: 200, y: 200, width: 1100, height: 720)))
        defer {
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let window = try #require(controller.window)
        let pool = NewTabSparePool(services: services, memoryPressure: services.memoryPressure)
        // Each stand-in page keeps the pool's `whenPainted` body; `paint[i]` is page i drawing.
        var waiters: [() -> Void] = []
        pool.shownChats.standIn = { (0..<loading).map { _ in { waiters.append($0) } } }
        let paint: [() -> Void] = (0..<loading).map { index in { if index < waiters.count { waiters[index]() } } }
        try await body(pool, window, paint, { waiters.count })
        pool.dropAll()
    }

    /// Waits for a state the pool's own timers reach (the launch warm, the shown-chats deadline): a poll of that
    /// state bounded by a deadline, never a fixed sleep. Long enough for the 3 s shown-chats deadline on a busy runner.
    private static func until(_ reached: () -> Bool, within limit: Duration = .seconds(30)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while !reached(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func theLaunchSpareWaitsUntilEveryShownChatDrew() async throws {
        try await Self.withPool(loading: 2) { pool, window, paint, asked in
            pool.retarget(window)
            // The launch warm ran and asked to wait on both shown chats: it holds the spare.
            await Self.until { asked() == 2 }
            #expect(asked() == 2, "the launch warm never asked about the shown chats")
            #expect(pool.nativeSpare == nil, "the spare was made while the shown chats were still loading")
            paint[0]()
            // One page drawing runs nothing while the other still loads (the wait counts down at once).
            #expect(pool.nativeSpare == nil, "the spare was made while one shown chat was still loading")
            paint[1]()
            await Self.until { pool.nativeSpare != nil }
            #expect(pool.nativeSpare != nil, "no spare after every shown chat drew")
        }
    }

    @Test func withNoShownChatLoadingTheSpareComesAtOnce() async throws {
        try await Self.withPool(loading: 0) { pool, window, _, _ in
            pool.retarget(window)
            await Self.until { pool.nativeSpare != nil }
            #expect(pool.nativeSpare != nil, "no spare after the launch warm")
        }
    }

    @Test func aShownChatThatNeverDrawsHoldsTheSpareOnlyUntilTheDeadline() async throws {
        try await Self.withPool(loading: 1) { pool, window, _, asked in
            pool.retarget(window)
            await Self.until { asked() == 1 }
            #expect(asked() == 1, "the launch warm never asked about the shown chat")
            #expect(pool.nativeSpare == nil)
            // The page never draws: only the wait's deadline ends the hold.
            await Self.until { pool.nativeSpare != nil }
            #expect(pool.nativeSpare != nil, "a page that never drew kept the spare away past the deadline")
        }
    }
}
