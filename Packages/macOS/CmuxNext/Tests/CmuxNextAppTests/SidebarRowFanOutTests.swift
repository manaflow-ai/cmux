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
/// model change is O(changed items), never O(session)). The rows are the app's own mapping (`SidebarBridge.sections`
/// with `AppServices.sidebarPageFace` and `SidebarBridge.tabTitle`) through a row feed whose frame the test runs by
/// hand, so every count is exact and nothing waits on time. `row_invalidations` counts the rows whose observation
/// fired, `row_maps` the rows mapped again.
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

    /// One window's rows over `count` workspaces through a row feed whose frames run only in `frame()`.
    @MainActor final class Fixture {
        let services: AppServices
        let state: WindowState
        let feed: SidebarRowFeed
        final class Frames { var work: [@MainActor @Sendable () -> Void] = [] }
        let frames = Frames()
        /// The rows the last pass listed.
        private(set) var listed = 0

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            let store = services.machines.local.store
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            store.apply(snapshot: SidebarRowFanOutTests.tree())
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"fan-out","workspace_key":"fan-out-home"}"#.utf8))
            state = WindowState(record: record)
            services.windows.registry.provisional[state.id] = SidebarRowFanOutTests.keys
            feed = SidebarRowFeed(schedule: { [frames] work in frames.work.append(work) })
            pass()
            frame()
        }

        /// The structural pass, as the window's sidebar runs it: every listed row named, new rows mapped and observed.
        func pass() {
            feed.beginPass(inputs: 0)
            let sections = SidebarBridge.sections(services.machines, doc: services.sidebarDoc, members: SidebarRowFanOutTests.keys,
                                                  profile: state.profileID, pageFace: services.sidebarPageFace,
                                                  tabTitle: SidebarBridge.tabTitle(services), rows: feed.rowSource)
            listed = feed.fill(sections).flatMap(\.workspaces).count
        }

        /// One display frame: the row feed's flush maps its dirty rows again and arms them.
        func frame() {
            let work = frames.work
            frames.work.removeAll()
            work.forEach { $0() }
        }

        /// The rows `body` invalidated and the rows mapped again by the pass and the frame that follow it.
        func cost(_ body: () -> Void) -> (invalidated: Int, mapped: Int) {
            _ = SidebarPerfCounters.report(reset: true)
            body()
            pass()
            frame()
            let report = SidebarPerfCounters.report(reset: true)
            return (report["row_invalidations"] ?? 0, report["row_maps"] ?? 0)
        }
    }

    @Test func aTabChangeInOneWorkspaceInvalidatesOnlyItsRow() throws {
        let fixture = try Fixture()
        defer { fixture.feed.reset() }
        let store = fixture.services.machines.local.store
        #expect(fixture.listed == Self.count, "the fixture lists every workspace")
        // The CLI storm makes a terminal tab in its own workspace, moves it, then closes it.
        let made = fixture.cost { store.apply(snapshot: Self.tree { Self.workspace($0, index: $1, extra: 1) }) }
        let moved = fixture.cost { store.apply(snapshot: Self.tree { Self.workspace($0, index: $1, extra: 1, reversed: true) }) }
        let closed = fixture.cost { store.apply(snapshot: Self.tree()) }
        print("SIDEBAR-FAN-OUT n=\(Self.count) made=\(made) moved=\(moved) closed=\(closed)")
        #expect(made.invalidated == 1, "a tab made in one workspace invalidated \(made.invalidated) of \(Self.count) rows")
        #expect(moved.invalidated == 1, "a tab moved in one workspace invalidated \(moved.invalidated) of \(Self.count) rows")
        #expect(closed.invalidated == 1, "a tab closed in one workspace invalidated \(closed.invalidated) of \(Self.count) rows")
        #expect(made.mapped == 1 && moved.mapped == 1 && closed.mapped == 1,
                "rows mapped again: \(made.mapped), \(moved.mapped), \(closed.mapped) of \(Self.count)")
    }

    @Test func aWorkspaceMadeOrClosedInvalidatesNoOtherRow() throws {
        let fixture = try Fixture()
        defer { fixture.feed.reset() }
        let store = fixture.services.machines.local.store
        // An agent makes a workspace the window does not list, then closes one it does.
        let made = fixture.cost { store.apply(snapshot: Self.tree(Self.keys + ["k900"])) }
        let closed = fixture.cost { store.apply(snapshot: Self.tree(Self.keys.filter { $0 != "k017" })) }
        print("SIDEBAR-FAN-OUT workspaces n=\(Self.count) made=\(made) closed=\(closed)")
        #expect(made.invalidated == 0, "a workspace made elsewhere invalidated \(made.invalidated) of \(Self.count) rows")
        // At most the closed workspace's own row (it leaves the sidebar), never the others.
        #expect(closed.invalidated <= 1, "a workspace closed invalidated \(closed.invalidated) of \(Self.count) rows")
        // The pass names every workspace of the daemon before it keeps the window's members, so the new one is
        // mapped once (its own first map); no listed row is mapped again.
        #expect(made.mapped <= 1 && closed.mapped == 0, "rows mapped again: \(made.mapped), \(closed.mapped) of \(Self.count)")
    }
}
