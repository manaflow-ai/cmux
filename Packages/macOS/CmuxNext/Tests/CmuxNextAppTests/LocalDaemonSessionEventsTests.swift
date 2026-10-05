import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// nxdog50: on a first launch the local daemon served the state resources
/// (closed history, workspace status, ...) but the app never mirrored them
/// (session_known false, mirror false), so no undo toast could show. The
/// first connect begun in `main` (`DaemonService.prestart`) must open
/// `session.events` like every later connection.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct LocalDaemonSessionEventsTests {
    @Test func theFirstLocalConnectMirrorsTheSessionState() async throws {
        let state = #"{"closed":[{"id":"closed_1","kind":"tab","name":"t","workspace_id":"ws_w","pane_id":"pane_p","index":0,"closed_at_ms":"5","screens":[]}]}"#
        let daemon = try StateDaemon(state: state)
        defer { daemon.stop() }
        let configuration = DaemonService.localConfiguration(terminalEnvironment: nil, resolvesShellIntegration: false, installKey: nil)
        let endpoint = DaemonEndpoint(socketPath: daemon.socket.path)
        // The prestart path: one connection started before the service runs it.
        let first = DaemonConnection(endpoint: endpoint, configuration: configuration)
        let identity = try await first.start()
        let services = ActionBindingCoverageTests.boundServices()
        services.daemon.start(first: { .success((first, identity)) },
                              makeConnection: { DaemonConnection(endpoint: endpoint, configuration: configuration) })
        defer { services.daemon.shutdownConnection() }
        try await waitForCondition("the session state is mirrored", timeout: .seconds(10), sourceLocation: #_sourceLocation) {
            services.daemon.store.session.known && services.daemon.store.session.mirror != nil
        }
        #expect(services.daemon.store.closedItems.map(\.id) == ["closed_1"])
    }
}
