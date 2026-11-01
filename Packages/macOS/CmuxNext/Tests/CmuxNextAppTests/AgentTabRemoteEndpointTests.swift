@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import Testing

/// The pane's endpoint provider must follow a machine reconnect, which replaces the Cloud ticket.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AgentTabRemoteEndpointTests {
    private actor Steps {
        var values: [String] = []
        func note(_ value: String) { values.append(value) }
    }

    @Test func enrollmentFinishesBeforeResolvingThePostRestartSurface() async throws {
        let steps = Steps()
        var host = AgentTabRemoteHost(surface: 1, session: "chat", machine: "Cloud", hostID: "Cloud", endpoint: { throw CancellationError() })
        host.prepareCloudTurns = { await steps.note("enroll") }
        host.existing = {
            await steps.note("resolve")
            return (surface: 9, session: "chat")
        }
        _ = try await host.handshake(sessionId: nil)
        #expect(await steps.values == ["enroll", "resolve"])
    }

    @Test func failedEnrollmentCannotStartOrResolveAChat() async {
        let steps = Steps()
        var host = AgentTabRemoteHost(surface: 1, session: "chat", machine: "Cloud", hostID: "Cloud", endpoint: { throw CancellationError() })
        host.prepareCloudTurns = { throw CancellationError() }
        host.existing = {
            await steps.note("resolve")
            return (surface: 9, session: "chat")
        }
        host.start = { _, _, _, _ in
            await steps.note("start")
            return .init(surface: 9, session: "chat")
        }
        await #expect(throws: CancellationError.self) { try await host.handshake(sessionId: nil) }
        await #expect(throws: CancellationError.self) { try await host.startNow(cwd: nil, harness: "claude", proceed: {}) }
        #expect(await steps.values.isEmpty)
    }

    @Test func readOnlyAttachmentDoesNotEnrollTheOwnersMachine() async throws {
        var host = AgentTabRemoteHost(surface: 1, session: "chat", machine: "Cloud", hostID: "Cloud", endpoint: { throw CancellationError() })
        host.mode = .observe
        host.prepareCloudTurns = { throw CancellationError() }
        _ = try await host.handshake(sessionId: nil)
    }

    @Test func canceledStartDoesNotEnroll() async {
        let steps = Steps()
        var host = AgentTabRemoteHost(surface: 1, session: nil, machine: "Cloud", hostID: "Cloud", endpoint: { throw CancellationError() })
        host.prepareCloudTurns = { await steps.note("enroll") }
        host.start = { _, _, _, _ in
            await steps.note("start")
            return .init(surface: 9, session: "chat")
        }
        await #expect(throws: CancellationError.self) {
            try await host.startNow(cwd: nil, harness: "claude", proceed: { throw CancellationError() })
        }
        #expect(await steps.values.isEmpty)
    }

    @Test func reconnectRetriesWithTheReplacementEndpoint() async throws {
        let daemon = DaemonService(machineID: "cloud:fixture")
        daemon.start(remote: { throw DaemonError.notConnected })
        // Keep the endpoint provider but cancel the background daemon connection before it runs.
        daemon.shutdownConnection()
        let endpoint = AgentTabRemoteHost.endpoint(on: daemon)

        let recovered = try await AgentSessionAttachClient.retrying({ _ in try await endpoint() }, reconnect: {
            await MainActor.run {
                daemon.start(remote: { "/fixture/reconnected-ticket.sock" })
                daemon.shutdownConnection()
            }
            return true
        })

        #expect(recovered.socketPath == "/fixture/reconnected-ticket.sock")
    }
}
