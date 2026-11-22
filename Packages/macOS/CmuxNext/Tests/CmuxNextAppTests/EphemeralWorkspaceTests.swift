@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Incognito workspaces on a daemon with state resources are ephemeral: the
/// app creates them with `workspace.create {ephemeral: true}`, recognizes
/// them by the daemon's flag, and treats a flagged workspace at launch as a
/// leftover to close (no crash ledger).
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct EphemeralWorkspaceTests {
    nonisolated static let flagged = #""workspaces":[{"id":"ws_w","session_id":"session_s","name":"w","index":0,"focused":true,"extra":{"ephemeral":true}}]"#

    nonisolated static func reply(_ operation: String, _ params: [String: JSONValue]) -> String {
        guard operation == "workspace.create" else { return "{}" }
        return #"{"kind":"terminal","workspace_id":"ws_new","screen_id":"screen_n","pane_id":"pane_n","tab_id":"tab_n","terminal_id":"term_n"}"#
    }

    /// Waits up to 10 s; a timeout records an Issue at the caller (``waitForCondition``).
    func waitUntil(_ what: String? = nil, sourceLocation: SourceLocation = #_sourceLocation,
                   _ condition: () -> Bool) async throws {
        try await waitForCondition(what, timeout: .seconds(10), sourceLocation: sourceLocation, condition)
    }

    func services(_ daemon: StateDaemon) async throws -> AppServices {
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.start(makeConnection: { daemon.connection() })
        try await waitUntil { services.daemon.store.isLoaded && services.daemon.store.servesStateResources && services.daemon.store.session.known }
        return services
    }

    /// The daemon closes ephemeral workspaces; the app never does, even ones
    /// a crashed run left.
    @Test func aFlaggedWorkspaceIsIncognitoAndNeverClosedByTheApp() async throws {
        let daemon = try StateDaemon(state: "{}", entities: Self.flagged)
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { services.daemon.shutdownConnection() }
        let key = StateDaemon.workspaceKey
        #expect(services.daemon.store.workspaces.first?.ephemeral == true)
        #expect(services.windows.isIncognito(workspace: key))
        await EphemeralWorkspaces.awaitFlags(services.windows)
        #expect(!services.windows.registry.value.discarding.contains(key))
        #expect(!daemon.operations.contains("workspace.close"))
        // Its id is never written to the app's crash ledger.
        #expect(EphemeralWorkspaces.isEphemeral(key, services.windows))
    }

    @Test func newIncognitoWindowCreatesAnEphemeralWorkspace() async throws {
        let daemon = try StateDaemon(state: "{}", reply: Self.reply)
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { services.daemon.shutdownConnection() }
        let window = services.windows.newIncognitoWindow()
        #expect(services.windows.isIncognito(window: window))
        try await waitUntil { daemon.operations.contains("workspace.create") }
        let params = try #require(daemon.params(of: "workspace.create"))
        #expect(params["ephemeral"] == .bool(true))
        #expect(params["initial_content"] == .string("terminal"))
        #expect(daemon.requests.last { $0["operation"]?.stringValue == "workspace.create" }?["idempotency_key"] != nil)
    }

    @Test func aHeldOrphanStaysOutOfEveryWindow() {
        var registry = WindowRegistry()
        registry.reconcile(live: ["a"], dead: [], fallbackWindow: "w1")
        let changes = registry.reconcile(live: ["a", "b"], dead: [], held: ["b"], fallbackWindow: "w2")
        #expect(registry.owner(of: "b") == nil)
        #expect(changes.moved.values.flatMap { $0 }.contains("b") == false)
        registry.reconcile(live: ["a", "b"], dead: [], fallbackWindow: "w2")
        #expect(registry.owner(of: "b") == "w1")
    }
}
