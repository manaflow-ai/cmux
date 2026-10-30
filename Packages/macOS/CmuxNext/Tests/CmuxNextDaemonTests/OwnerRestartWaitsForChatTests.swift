import Foundation
import Testing
@testable import CmuxNextDaemon

/// hq-6d, 2026-10-14: a DEV app restarts its keyless Chief owner once, only while
/// the owner is idle (`IdleOwnerRestart` over `OwnerIdleProbe`). An open `cmux chief`
/// chat is a client of kind `chief-chat` (cmux-tui cli/chief, tests/cli/chief_chat_kind.rs):
/// while it is attached the restart waits; when it detaches, the owner's `client-detached`
/// event runs the restart. A real daemon; the chat is a second client that names itself as
/// the CLI chat does (`client.metadata.update` kind `chief-chat`).
/// A `cmux` CLI or MCP call names no kind (cmux-tui cli): while one is connected the restart
/// waits too, so the owner is not restarted in the middle of its request.
@Suite(.enabled(if: RealBinary.url != nil, "no cmux-tui binary available"), .liveDaemon)
struct OwnerRestartWaitsForChatTests {
    @Test func theRestartWaitsWhileACLIChatIsAttachedAndRunsAfterItDetaches() async throws {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-chat-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ProcessInfo.processInfo.environment
        let environment = LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:])
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cnd-chat-\(id)", stateDirectory: root.appendingPathComponent("state"),
                                 installKey: FrontendInstallKey.generate()),
            environment: { environment })
        // The app's owner connection; it reconnects to the restarted owner by itself.
        let owner = DaemonConnection(endpointProvider: launcher.endpointProvider)
        var chat: DaemonConnection?
        do {
            _ = try await launcher.ensure()
            let old = try await owner.start()
            let endpoint = try #require(await owner.endpoint)
            // The chat: its own connection to the same socket, never `server ensure`.
            let chatConnection = DaemonConnection(endpoint: endpoint, configuration: .init(clientName: "cmux chief"))
            chat = chatConnection
            _ = try await chatConnection.start()
            let named = try await chatConnection.resourceRequest({ id in
                ResourceRequestEnvelope(id: id, operation: "client.metadata.update",
                                        params: ["client": .string("current"), "name": .string("cmux chief"),
                                                 "kind": .string("chief-chat")])
            }, as: JSONValue.self)
            #expect(named["client_kind"]?.stringValue == "chief-chat", "\(named)")

            let restart = IdleOwnerRestart(probe: OwnerIdleProbe(owner)) {
                await launcher.handOffForInstallKey(identity: old, using: owner)
            }
            // While the chat is attached: no restart.
            #expect(await restart.attempt() == .waiting)
            #expect(await owner.identity?.pid == old.pid, "the owner restarted under an open chat")

            // The chat ends; the owner's events run the restart (client-detached), or the restart's
            // own attempt once the daemon's standing clients without a kind are a minute old.
            await chatConnection.close()
            let outcome = try await Self.firstOutcome(of: restart, on: owner, timeout: Self.restartTimeout)
            #expect(outcome == .started)
            try await Self.expectNewOwner(after: old, on: owner)
        } catch {
            await chat?.close()
            await BranchDaemonHarness.shutDown(owner)
            throw error
        }
        await BranchDaemonHarness.shutDown(owner)
    }

    /// A `cmux` CLI or MCP call in flight: a fresh local client that names no kind. The restart
    /// waits while it is connected (it counted as idle before, and the owner restarted under the
    /// call's request), and runs once the call has ended.
    @Test func theRestartWaitsWhileACLICallWithoutAKindIsConnected() async throws {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-call-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ProcessInfo.processInfo.environment
        let environment = LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:])
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cnd-call-\(id)", stateDirectory: root.appendingPathComponent("state"),
                                 installKey: FrontendInstallKey.generate()),
            environment: { environment })
        let owner = DaemonConnection(endpointProvider: launcher.endpointProvider)
        var cli: DaemonConnection?
        do {
            _ = try await launcher.ensure()
            let old = try await owner.start()
            let endpoint = try #require(await owner.endpoint)
            // The call: its own connection to the same socket that names no kind, as the CLI's does.
            let call = DaemonConnection(endpoint: endpoint, configuration: .init(clientName: "cmux"))
            cli = call
            _ = try await call.start()
            let cleared = try await call.resourceRequest({ rid in
                ResourceRequestEnvelope(id: rid, operation: "client.metadata.update",
                                        params: ["client": .string("current"), "kind": .null])
            }, as: JSONValue.self)
            #expect(cleared["client_kind"] == .null, "\(cleared)")

            let restart = IdleOwnerRestart(probe: OwnerIdleProbe(owner)) {
                await launcher.handOffForInstallKey(identity: old, using: owner)
            }
            // While the call is connected: no restart.
            #expect(await restart.attempt() == .waiting)
            #expect(await owner.identity?.pid == old.pid, "the owner restarted under a CLI call")

            // The call ends; the restart runs.
            await call.close()
            cli = nil
            let outcome = try await Self.firstOutcome(of: restart, on: owner, timeout: Self.restartTimeout)
            #expect(outcome == .started)
            // Shut down the new owner, not the old one's removed socket.
            try await Self.expectNewOwner(after: old, on: owner)
        } catch {
            await cli?.close()
            await BranchDaemonHarness.shutDown(owner)
            throw error
        }
        await BranchDaemonHarness.shutDown(owner)
    }

    /// The owner is a new process on the same session state: the connection reconnected to it.
    private static func expectNewOwner(after old: DaemonIdentity, on owner: DaemonConnection) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        var current = await owner.identity
        while current?.pid == old.pid || current == nil {
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(100))  // test harness poll of the reconnect
            current = await owner.identity
        }
        #expect(current != nil && current?.pid != old.pid, "no new owner took over")
        #expect(current?.registryID == old.registryID)
    }

    /// How long a test waits for the restart: the daemon's own clients without a kind (its agent
    /// screen detector) count as a call for their first minute, so a fresh owner may wait that long.
    private static let restartTimeout: Duration = .seconds(90)

    /// Feeds the owner's events to `restart` until it leaves `.waiting`, or the restart's own
    /// attempt decides it; `.waiting` when neither did within `timeout`.
    private static func firstOutcome(of restart: IdleOwnerRestart, on owner: DaemonConnection,
                                     timeout: Duration) async throws -> IdleOwnerRestart.Outcome {
        try await withThrowingTaskGroup(of: IdleOwnerRestart.Outcome.self) { group in
            group.addTask {
                for try await envelope in owner.events {
                    let outcome = await restart.note(envelope.event)
                    if outcome != .waiting { return outcome }
                }
                return await restart.outcome
            }
            group.addTask {
                // The restart's own attempt when a client without a kind stops counting as a call.
                while await restart.outcome == .waiting {
                    try await Task.sleep(for: .milliseconds(250))  // test harness poll of the outcome
                }
                return await restart.outcome
            }
            group.addTask {
                try await Task.sleep(for: timeout)  // test harness bound for an event that never comes
                return await restart.outcome
            }
            let first = try await group.next() ?? .waiting
            group.cancelAll()
            return first
        }
    }
}
