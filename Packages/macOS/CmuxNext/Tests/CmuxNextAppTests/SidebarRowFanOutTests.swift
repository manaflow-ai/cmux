import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// TYPING UNDER LOAD F6 (Lawrence 2026-11-02: "typing into terminals is never laggy, even when there's a lot of
/// CLI/mcp commands and browser use and browser tabs going on in the background"). Under the L6 load the main thread
/// spent 37 % of its long turns in `SidebarRowFeed.flush`: each row's mapping read whole-session values (every
/// daemon's tab list revision and workspace list through the incognito lookup of each browser tab, the workspace list
/// through the auto name's daemon lookup), so a tab made, closed or moved in ONE background workspace marked every
/// row with a browser tab dirty and the next frame mapped them all again, between the person's keys.
///
/// A scripted change in one workspace invalidates that workspace's row only (CLAUDE.md: a scripted change's local
/// model change is O(changed items), never O(session)). `row_invalidations` counts the rows whose observation fired.
@MainActor @Suite(.serialized) struct SidebarRowFanOutTests {
    nonisolated static let count = 40
    static var keys: [String] { (0..<count).map { String(format: "k%03d", $0) } }
    /// The workspace the load works in (never shown).
    static let storm = "k000"

    /// Workspace `key`'s tabs: a terminal and a browser tab, plus `extra` more terminals.
    static func workspace(_ key: String, index: Int, extra: Int = 0, reversed: Bool = false) -> WorkspaceSnapshot {
        let base = UInt64(index + 1) * 100
        var browser = TabSnapshot(surface: SurfaceID(rawValue: base + 2), kind: .browser, cwd: nil)
        browser.url = "https://example.com/\(key)"
        browser.title = "Page \(key)"
        var tabs = [TabSnapshot(surface: SurfaceID(rawValue: base + 1), kind: .pty, cwd: "/tmp/\(key)"), browser]
        for e in 0..<extra { tabs.append(TabSnapshot(surface: SurfaceID(rawValue: base + 10 + UInt64(e)), kind: .pty, cwd: "/tmp/\(key)")) }
        if reversed { tabs.reverse() }
        let pane = PaneSnapshot(id: PaneID(rawValue: base), tabs: tabs)
        let screen = ScreenSnapshot(id: ScreenID(rawValue: base), layout: .leaf(PaneID(rawValue: base)), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
    }

    /// The home session's tree: `keys` in order, the storm workspace as `storm` makes it.
    static func tree(_ keys: [String] = keys, storm: (String, Int) -> WorkspaceSnapshot = { workspace($0, index: $1) }) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.map { key in
            let index = Int(key.dropFirst())!
            return key == Self.storm ? storm(key, index) : workspace(key, index: index)
        })
        tree.personal = PersonalState(groups: [], workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index, group: nil)
        })
        return tree
    }

    /// One window's sidebar over `count` workspaces, every row mapped and observed.
    static func sidebar() throws -> (AppServices, SidebarBridge) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"fan-out","workspace_key":"fan-out-home"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = keys
        let bridge = SidebarBridge(services: services, state: state)
        bridge.sameTurn.syncNow(rows: true)
        return (services, bridge)
    }

    /// Lets the row feed's frame flush run: it maps the dirty rows again and arms them, so the next phase starts with
    /// every row observed (the flush waits for a display frame, or the frame scheduler's stall deadline).
    static func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// The rows `body` invalidated, and the rows mapped again (the structural pass that follows it and the flush).
    static func cost(_ bridge: SidebarBridge, _ body: () -> Void) async -> (invalidated: Int, mapped: Int) {
        await settle()
        _ = SidebarPerfCounters.report(reset: true)
        body()
        bridge.sameTurn.syncNow(rows: true)
        await settle()
        let report = SidebarPerfCounters.report(reset: true)
        return (report["row_invalidations"] ?? 0, report["row_maps"] ?? 0)
    }

    @Test func aTabChangeInOneWorkspaceInvalidatesOnlyItsRow() async throws {
        let (services, bridge) = try Self.sidebar()
        defer { bridge.teardown() }
        let store = services.machines.local.store
        #expect(bridge.model.sections.flatMap(\.workspaces).count == Self.count, "the fixture lists every workspace")
        // The CLI storm makes a terminal tab in its own workspace, moves it, then closes it.
        let made = await Self.cost(bridge) { store.apply(snapshot: Self.tree { Self.workspace($0, index: $1, extra: 1) }) }
        let moved = await Self.cost(bridge) { store.apply(snapshot: Self.tree { Self.workspace($0, index: $1, extra: 1, reversed: true) }) }
        let closed = await Self.cost(bridge) { store.apply(snapshot: Self.tree()) }
        print("SIDEBAR-FAN-OUT n=\(Self.count) made=\(made) moved=\(moved) closed=\(closed)")
        #expect(made.invalidated <= 1, "a tab made in one workspace invalidated \(made.invalidated) of \(Self.count) rows")
        #expect(moved.invalidated <= 1, "a tab moved in one workspace invalidated \(moved.invalidated) of \(Self.count) rows")
        #expect(closed.invalidated <= 1, "a tab closed in one workspace invalidated \(closed.invalidated) of \(Self.count) rows")
        #expect(made.mapped <= 1 && moved.mapped <= 1 && closed.mapped <= 1,
                "rows mapped again: \(made.mapped), \(moved.mapped), \(closed.mapped) of \(Self.count)")
    }

    @Test func aWorkspaceMadeOrClosedInvalidatesNoOtherRow() async throws {
        let (services, bridge) = try Self.sidebar()
        defer { bridge.teardown() }
        let store = services.machines.local.store
        // An agent makes a workspace the window does not list, then closes one it does.
        let made = await Self.cost(bridge) { store.apply(snapshot: Self.tree(Self.keys + ["k900"])) }
        let closed = await Self.cost(bridge) { store.apply(snapshot: Self.tree(Self.keys.filter { $0 != "k017" })) }
        print("SIDEBAR-FAN-OUT workspaces n=\(Self.count) made=\(made) closed=\(closed)")
        #expect(made.invalidated == 0, "a workspace made elsewhere invalidated \(made.invalidated) of \(Self.count) rows")
        // At most the closed workspace's own row (it leaves the sidebar), never the others.
        #expect(closed.invalidated <= 1, "a workspace closed invalidated \(closed.invalidated) of \(Self.count) rows")
    }
}
