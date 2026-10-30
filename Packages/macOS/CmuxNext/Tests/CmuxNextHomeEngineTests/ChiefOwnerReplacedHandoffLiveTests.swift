@testable import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import os
import Testing

/// The cmux-tui the suite runs, or nil to skip it. A file-level value, not a static of the suite:
/// a `@Suite` trait that names the type it decorates is a circular macro reference.
private let chiefOwnerHandoffBinary: URL? = {
    let environment = ProcessInfo.processInfo.environment
    return ["CMUX_NEXT_TUI_TREE_PATH", DaemonLauncher.binaryOverrideKey]
        .compactMap { environment[$0] }
        .first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
        .map(URL.init(fileURLWithPath:))
}()

/// A real owner through `ChiefConversationOwner.restartIfReplaced`: an owner whose binary an update
/// removed (its `cli_path` names a file that is gone) is handed off to the bundled build, and only
/// while it is idle. Under an open `cmux chief` chat (a client of kind `chief-chat`) it waits; once
/// the chat detaches the owner's events run it. The same owner reporting its own existing binary
/// and build is never handed off. Runs where the suite runner resolved the tree's cmux-tui
/// (`CMUX_NEXT_TUI_TREE_PATH`) or an override names one (`CMUX_NEXT_TUI_BIN`).
@MainActor
@Suite(.enabled(if: chiefOwnerHandoffBinary != nil, "no cmux-tui binary available"))
struct ChiefOwnerReplacedHandoffLiveTests {
    @Test func aReplacedOwnerHandsOffOnlyOnceTheChatDetaches() async throws {
        let binary = try #require(chiefOwnerHandoffBinary)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/che-upd-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = LoginEnvironment.shared.daemonEnvironment(login: nil, base: ProcessInfo.processInfo.environment,
                                                                    overrides: [:])
        // `binaryIsBundled`, as the app's own launcher: an update handoff is refused for an external binary.
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "che-upd-\(id)", stateDirectory: root.appendingPathComponent("state"),
                                 binaryIsBundled: true),
            environment: { environment })
        let owner = DaemonConnection(endpointProvider: launcher.endpointProvider)
        let logger = Logger(subsystem: "com.cmuxterm.app.next.tests", category: "home")
        var chat: DaemonConnection?
        do {
            _ = try await launcher.ensure()
            let old = try await owner.start()
            // As it is: its own existing binary and build. Never handed off.
            #expect(await ChiefConversationOwner.restartIfReplaced(launcher: launcher, connection: owner, identity: old,
                                                                   logger: logger) == nil)

            let endpoint = try #require(await owner.endpoint)
            let chatConnection = DaemonConnection(endpoint: endpoint, configuration: .init(clientName: "cmux chief"))
            chat = chatConnection
            _ = try await chatConnection.start()
            _ = try await chatConnection.resourceRequest({ rid in
                ResourceRequestEnvelope(id: rid, operation: "client.metadata.update",
                                        params: ["client": .string("current"), "name": .string("cmux chief"),
                                                 "kind": .string("chief-chat")])
            }, as: JSONValue.self)

            // The same owner as an update leaves it: the file it says it runs is gone.
            var replaced = old
            replaced.cliPath = root.appendingPathComponent("gone/cmux-tui").path
            let restart = try #require(await ChiefConversationOwner.restartIfReplaced(
                launcher: launcher, connection: owner, identity: replaced, logger: logger))
            #expect(await restart.outcome == .waiting, "handed off under an open chat")
            #expect(await owner.identity?.pid == old.pid)

            await chatConnection.close()
            chat = nil
            let outcome = try await Self.firstOutcome(of: restart, on: owner, timeout: .seconds(90))
            #expect(outcome == .started)
            try await Self.expectNewOwner(after: old, on: owner)
        } catch {
            await chat?.close()
            await Self.shutDown(owner)
            throw error
        }
        await Self.shutDown(owner)
    }

    /// Feeds the owner's events to `restart` until it leaves `.waiting`, or the restart's own attempt
    /// decides it; `.waiting` when neither did within `timeout`.
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

    /// Stops reconnecting, then ends the owner and its terminals, so nothing outlives the test.
    private static func shutDown(_ connection: DaemonConnection) async {
        await connection.close()
        _ = try? await connection.shutdownDaemon(endTerminals: true)
    }
}
