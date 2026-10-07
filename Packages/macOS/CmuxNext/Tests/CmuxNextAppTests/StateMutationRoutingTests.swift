import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// On a daemon with state resources, screen metadata, screen groups and
/// workspace identity go through the v2 state operations with idempotency
/// keys.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct StateMutationRoutingTests {
    func services(_ daemon: StateDaemon) async throws -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.start(makeConnection: { daemon.connection() })
        let clock = ContinuousClock(), end = clock.now.advanced(by: .seconds(10))
        while !(services.daemon.store.isLoaded && services.daemon.store.servesStateResources && services.daemon.store.session.known), clock.now < end {
            try await clock.sleep(for: .milliseconds(20)) // test-only wait
        }
        return services
    }

    func waitFor(_ daemon: StateDaemon, _ operation: String) async throws {
        let clock = ContinuousClock(), end = clock.now.advanced(by: .seconds(10))
        while !daemon.operations.contains(operation), clock.now < end { try await clock.sleep(for: .milliseconds(20)) }
    }

    @Test func screenAndWorkspaceEditsUseTheV2Operations() async throws {
        let daemon = try StateDaemon(state: "{}")
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { services.daemon.shutdownConnection() }
        let workspace = try #require(services.daemon.store.workspaces.first)
        let screen = try #require(workspace.screens.first)

        ScreenCommands.setColor(screen, "green", daemon: services.daemon)
        try await waitFor(daemon, "screen.update")
        #expect(daemon.params(of: "screen.update")?["screen"] == .string("screen_s"))
        #expect(daemon.params(of: "screen.update")?["color"] == .string("green"))

        ScreenGroupCommands.create([screen], in: workspace, name: "Build", color: .orange, daemon: services.daemon)
        try await waitFor(daemon, "screen_group.create")
        #expect(daemon.params(of: "screen_group.create")?["screens"] == .array([.string("screen_s")]))

        let key = try #require(workspace.key)
        let resource = services.daemon.store.stateResourceID(workspace: key)
        #expect(resource == ResourceID(rawValue: "ws_w"))
        services.daemon.send("set-workspace-metadata") { try await $0.state.setWorkspaceIdentity(key, resource: resource, color: .set("red")) }
        try await waitFor(daemon, "workspace.update")
        #expect(daemon.params(of: "workspace.update")?["color"] == .string("red"))
        #expect(daemon.requests.allSatisfy { $0["operation"]?.stringValue == "session.events" || $0["idempotency_key"] != nil })
    }
}
