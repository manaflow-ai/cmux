import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The `large` session of plans/cmux-next/main-thread-scheduling.md 1.5, as a store fixture: 60 workspaces x 6 tabs =
/// 360 tabs. Each workspace has one screen with one pane of 3 terminals, 1 agent chat, 1 Chromium page and 1 WebKit page.
/// The window holds every workspace and shows workspace 60. The 5 agent terminals are the first terminal of workspaces
/// 1, 13, 25, 37 and 49: all hidden.
///
/// ``withWindow(_:)`` opens a whole window through the app's real composition root (`AppServices`), so every observer the
/// app starts (sidebar, strip, link places, attention, favicons, the namer, ...) runs through its real init. Tests count
/// what a change wakes with `ObservationWakes`.
///
/// Not `LargeSessionFixture`: that name is the one shared 60 x 6 store fixture of #40126 (MTS-4 O2), which the row
/// tests use. This one opens a whole window through `AppServices`, so it keeps its own name and any merge order compiles.
@MainActor
enum LargeSessionWindowFixture {
    static let workspaces = 60
    static let tabsPerWorkspace = 6
    /// The surfaces of the 5 agent terminals, in 5 different hidden workspaces.
    static let agentSurfaces: [SurfaceID] = [1, 13, 25, 37, 49].map { surface(workspace: $0, index: 0) }
    /// A terminal of the shown workspace (60).
    static let shownTerminal = surface(workspace: workspaces, index: 0)

    static func key(_ workspace: Int) -> String { "large-ws-\(workspace)" }

    static func surface(workspace: Int, index: Int) -> SurfaceID {
        SurfaceID(rawValue: UInt64((workspace - 1) * tabsPerWorkspace + index + 1))
    }

    private static func tab(workspace: Int, index: Int) -> TabSnapshot {
        let id = surface(workspace: workspace, index: index)
        switch index {
        case 3:
            var chat = TabSnapshot(surface: id, kind: .conversation, title: "chat", browserRenderer: "frontend")
            chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", session: nil, harness: nil))
            return chat
        case 4:
            return TabSnapshot(surface: id, kind: .browser, url: "http://127.0.0.1:9/\(id.rawValue)", browserRenderer: "frontend", browserEngine: "cef")
        case 5:
            return TabSnapshot(surface: id, kind: .browser, url: "http://127.0.0.1:9/\(id.rawValue)", browserRenderer: "frontend", browserEngine: "webkit")
        default:
            return TabSnapshot(surface: id, title: "zsh")
        }
    }

    static func tree() -> DaemonTree {
        let snapshots = (1...workspaces).map { workspace in
            let pane = PaneSnapshot(id: PaneID(rawValue: UInt64(workspace)),
                                    tabs: (0..<tabsPerWorkspace).map { tab(workspace: workspace, index: $0) })
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(workspace)), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(workspace)), key: WorkspaceKey(rawValue: key(workspace)),
                                     name: "workspace \(workspace)", screens: [screen])
        }
        var tree = DaemonTree(registryID: "s-local", workspaces: snapshots)
        tree.personal = PersonalState(workspaces: (1...workspaces).map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key($0)), index: $0 - 1)
        })
        return tree
    }

    /// Lets the main actor run what is queued: a fixed number of yields, no wait for time to pass.
    static func drainMain() async {
        for _ in 0..<80 { await Task.yield() }
    }

    /// One `title-changed` line of the daemon, decoded as the connection decodes it. `text` and `activity` are the
    /// fields a daemon with D2 adds; a client that reads only `title` ignores them.
    static func titleChanged(_ surface: SurfaceID, raw: String, text: String, activity: String?) -> DaemonEvent {
        var line: [String: Any] = ["event": "title-changed", "surface": surface.rawValue, "title": raw, "text": text]
        line["activity"] = activity ?? NSNull()
        let data = (try? JSONSerialization.data(withJSONObject: line)) ?? Data()
        return DaemonEvent.decode(name: "title-changed", line: data)
    }

    /// Runs `body` on a whole window of the large session (its store), then closes it.
    static func withWindow<T>(_ body: @MainActor (DaemonStore) async throws -> T) async throws -> T {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let keys = [key(workspaces)] + (1..<workspaces).map(key)
        let controller = try #require(services.windows.openWindow(workspaces: keys, frame: CGRect(x: 200, y: 200, width: 1600, height: 900)))
        defer { controller.teardown(); controller.window?.close() }
        for _ in 0..<50 where controller.workspaceContent == nil { await drainMain() }
        let content = try #require(controller.workspaceContent)
        content.contentView.layoutSubtreeIfNeeded()
        await drainMain()
        try #require(store.workspaces.count == workspaces, "fixture: \(store.workspaces.count) workspaces, not \(workspaces)")
        return try await body(store)
    }
}
