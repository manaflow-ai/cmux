import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Reopen Closed Tab brings back the same live terminal while the daemon has
/// not reaped it yet (`terminal.project`), and a new shell in the saved
/// directory once it is gone.
@MainActor
struct ReopenClosedTabTests {
    final class Calls {
        var projected: [(ResourceID, PaneResourcePath, Int)] = []
        var spawned: [ClosedTerminalRestorer.Spawn] = []
    }

    static let identify = #"{"app":"cmux-tui","version":"0.1.0","protocol":12,"capabilities":[],"session":"t","pid":1,"registry_id":"r","generation":"GEN","workspace_revision":0}"#

    static func tab(_ surface: Int, _ name: String, cwd: String) -> String {
        #"{"surface":\#(surface),"kind":"pty","cwd":"\#(cwd)","tab_resource_id":"tab_\#(name)","terminal_id":"\#(String(repeating: name, count: 32).prefix(32))","terminal_resource_id":"term_\#(name)","title":""}"#
    }

    static func tree(_ tabs: [String]) throws -> DaemonTree {
        let json = #"{"workspace_revision":1,"generation":"GEN","registry_id":"r","workspaces":[{"id":1,"key":"0b8a2f1e-5a51-4c55-9f0e-6e2f6a4f9c01","name":"w","resource_id":"ws_w","screens":[{"id":4,"resource_id":"screen_s","layout":{"type":"leaf","pane":3},"panes":[{"id":3,"resource_id":"pane_p","active_tab":0,"tabs":[\#(tabs.joined(separator: ","))]}]}]}]}"#
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    /// Services with a connected store showing tabs a and b, then b closed.
    static func servicesAfterClosingB(project: @escaping (ResourceID) throws -> ResourceID) async throws -> (AppServices, Calls) {
        let services = ActionBindingCoverageTests.boundServices()
        let calls = Calls()
        let tracker = try #require(services.closedTabs)
        tracker.restorer = ClosedTerminalRestorer(
            isAvailable: { true },
            project: { terminal, path, index in
                calls.projected.append((terminal, path, index))
                return try project(terminal)
            },
            spawn: { spawn in
                calls.spawned.append(spawn)
                return SurfaceID(rawValue: 99)
            })
        let store = services.activeDaemon.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(identify.utf8))
        _ = store.apply(.connected(identity, generationChanged: false))
        store.apply(snapshot: try tree([tab(1, "a", cwd: "/tmp/a"), tab(2, "b", cwd: "/tmp/b")]))
        await settle { false }
        store.apply(snapshot: try tree([tab(1, "a", cwd: "/tmp/a")]))
        await settle { false }
        return (services, calls)
    }

    @Test func reopenWithinTheGracePeriodProjectsTheSameTerminal() async throws {
        let (services, calls) = try await Self.servicesAfterClosingB { _ in ResourceID(rawValue: "tab_restored") }
        let work = services.registry.capturingWork {
            _ = services.registry.perform("reopenClosedBrowserPanel", invocation: ActionInvocation())
        }
        for task in work { #expect(await task.value == nil) }
        #expect(calls.projected.count == 1)
        let (terminal, path, index) = try #require(calls.projected.first)
        #expect(terminal == ResourceID(rawValue: "term_b"))
        #expect(path == PaneResourcePath(workspace: ResourceID(rawValue: "ws_w"), screen: ResourceID(rawValue: "screen_s"),
                                         pane: ResourceID(rawValue: "pane_p")))
        #expect(index == 1)
        #expect(calls.spawned.isEmpty)
    }

    @Test func reopenAfterTheTerminalEndedStartsANewShellInItsDirectory() async throws {
        let (services, calls) = try await Self.servicesAfterClosingB { _ in
            throw DaemonError.command(cmd: "terminal.project", message: "terminal not found", code: "selector.not_found")
        }
        let work = services.registry.capturingWork {
            _ = services.registry.perform("reopenClosedBrowserPanel", invocation: ActionInvocation())
        }
        for task in work { #expect(await task.value == nil) }
        #expect(calls.projected.count == 1)
        let spawn = try #require(calls.spawned.first)
        #expect(spawn.cwd == "/tmp/b")
        #expect(spawn.index == 1)
        #expect(spawn.pane == PaneID(rawValue: 3))
    }
}
