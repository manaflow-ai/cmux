import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// The post-reply wait against a real daemon (`DaemonService.appliedThroughReply(on:after:)` and
/// `failureOnceApplied`). A command the daemon answered was committed before its reply, so when the
/// connection the caller waits on cannot decide (it is not the service's any more: New Workspace on Machine
/// reads the connection before its create waits in the window's lane, and a Cloud or server machine
/// reconnects with a new connection object), one barrier on the service's current connection does: the store
/// shows the result, and the caller answers with it instead of "unavailable, may have applied". A command
/// whose connection ends before the store catches up, with no other connection to decide, answers
/// ``ActionWorkFailure/resultNotShown``.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct AppliedThroughRecoveryTests {
    @Test func aWaitOnAConnectionThatIsNotTheServicesHoldsThroughABarrierOnTheCurrentOne() async throws {
        try await Self.withDaemon { daemon in
            let current = try #require(daemon.connection)
            let created = try await current.state.createWorkspace(name: "Barrier", ephemeral: false, terminal: true, focus: false)
            // The connection the caller read before its command ran: never the service's.
            let earlier = DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/tmp/cna-earlier-\(UUID().uuidString.prefix(8)).sock"))
            #expect(await daemon.appliedThroughReply(on: earlier, after: "test") == .held,
                    "a command the current connection ran was answered as not shown")
            #expect(daemon.store.workspace(resourceID: created.workspaceID) != nil, "held, but the store does not list the workspace")
        }
    }

    @Test func aCommandWhoseConnectionEndsBeforeTheStoreCatchesUpIsAResultNotShown() async throws {
        try await Self.withDaemon { daemon in
            let failure = await daemon.failureOnceApplied("test-ended", waits: false, while: { true }) { connection in
                _ = try await connection.request(IdentifyRequest())
                // The run ends after the reply and before the wait (a Quit, a removed machine).
                await connection.close()
            }
            #expect(failure == .resultNotShown, "a command whose result the store cannot show answered \(String(describing: failure))")
        }
    }

    /// Runs `body` with a service connected to a fresh same-tree daemon whose first snapshot applied, then
    /// ends the daemon with its terminals (through a connection of its own: `body` may close the service's).
    private static func withDaemon(_ body: (DaemonService) async throws -> Void) async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = URL(fileURLWithPath: "/private/tmp/cn-ryw-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment: @Sendable () -> [String: String] = {
            ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"]
        }
        let launcher = DaemonLauncher(configuration: .init(binary: binary, session: "cn-ryw-\(UUID().uuidString.prefix(6).lowercased())",
                                                           stateDirectory: root.appendingPathComponent("state")), environment: environment)
        let daemon = DaemonService()
        daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        let result: Result<Void, any Error>
        do {
            // Event-driven; the suite's time limit bounds it (a cancelled observation ends).
            for await ready in ObservationStream({ daemon.isLive && daemon.store.isLoaded }) where ready { break }
            #expect(daemon.isLive && daemon.store.isLoaded, "the service did not connect to the daemon")
            try await body(daemon)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        daemon.shutdownConnection()
        let reaper = DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        if (try? await reaper.start()) != nil { _ = try? await reaper.shutdownDaemon(endTerminals: true) }
        await reaper.close()
        try result.get()
    }
}
