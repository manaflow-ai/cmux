import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextDaemon

/// hq-6d, 2026-10-14: a DEV app restarts its keyless Chief owner once, only while
/// the owner is idle (`IdleOwnerRestart` over `OwnerIdleProbe`). An open `cmux chief`
/// chat is a client of kind `chief-chat` (cmux-tui cli/chief, tests/cli/chief_chat_kind.rs):
/// while it is attached the restart waits; when it detaches, the owner's `client-detached`
/// event runs the restart. A real daemon; the chat is a second client that names itself as
/// the CLI chat does (`client.metadata.update` kind `chief-chat`).
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
            work: BackgroundWork(label: "test.daemon-launcher"),
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

            // The chat ends; the owner's events run the restart (client-detached).
            await chatConnection.close()
            let outcome = try await Self.firstOutcome(of: restart, on: owner, timeout: .seconds(30))
            #expect(outcome == .started)

            // The owner is a new process on the same session state.
            let deadline = ContinuousClock.now + .seconds(60)
            var current = await owner.identity
            while current?.pid == old.pid || current == nil {
                if ContinuousClock.now >= deadline { break }
                try await Task.sleep(for: .milliseconds(100))  // test harness poll of the reconnect
                current = await owner.identity
            }
            #expect(current != nil && current?.pid != old.pid, "no new owner took over")
            #expect(current?.registryID == old.registryID)
        } catch {
            await chat?.close()
            await BranchDaemonHarness.shutDown(owner)
            throw error
        }
        await BranchDaemonHarness.shutDown(owner)
    }

    /// Feeds the owner's events to `restart` until it leaves `.waiting`; `.waiting` when no
    /// event moved it within `timeout`.
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
                try await Task.sleep(for: timeout)  // test harness bound for an event that never comes
                return await restart.outcome
            }
            let first = try await group.next() ?? .waiting
            group.cancelAll()
            return first
        }
    }
}
