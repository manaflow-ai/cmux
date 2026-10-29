@testable import CmuxNextAgentActivity
import Foundation
import Observation
import Testing

@MainActor
struct ComputerUseActivitySourceTests {
    @Test func sourceFollowsTheHelpersSocketAndFreshTokens() async throws {
        let settings = HelperConnection()
        var sent: [AgentActivitySocketSource.Configuration] = []
        let source = AgentActivitySocketSource(configuration: { settings.value }, send: { configuration, method, args in
            #expect(method == "activity_session_pause")
            #expect(args["id"] as? String == "s")
            sent.append(configuration)
            return [:]
        })
        var changed: CheckedContinuation<Void, Never>?
        source.start { _ in changed?.resume(); changed = nil }
        defer { source.stop() }
        await #expect(throws: AgentActivitySourceError.closed) { try await source.perform(.pause(session: "s")) }
        #expect(sent.isEmpty)
        let first = AgentActivitySocketSource.Configuration(socketPath: "/missing/first/cua.sock", authToken: "agent1",
                                                            hostAuthToken: "host1", machineName: "Test Mac")
        await withCheckedContinuation { continuation in
            changed = continuation
            settings.value = first
        }
        try await source.perform(.pause(session: "s"))
        #expect(sent == [first])
        let restarted = AgentActivitySocketSource.Configuration(socketPath: first.socketPath, authToken: "agent2",
                                                                hostAuthToken: "host2", machineName: "Test Mac")
        await withCheckedContinuation { continuation in
            changed = continuation
            settings.value = restarted
        }
        try await source.perform(.pause(session: "s"))
        #expect(sent == [first, restarted])
        await withCheckedContinuation { continuation in
            changed = continuation
            settings.value = nil
        }
        await #expect(throws: AgentActivitySourceError.closed) { try await source.perform(.pause(session: "s")) }
        #expect(sent == [first, restarted])
    }

    @Test(arguments: [AgentActivityUserOp.export(session: "s"), .openAgent(session: "s"), .openTarget(session: "s"),
                      .stopAll(machine: "local"), .watch(session: "s", on: true)])
    func unsupportedOperationsReportAnError(_ op: AgentActivityUserOp) async {
        let source = AgentActivitySocketSource(configuration: .init(socketPath: "/missing/cua.sock", machineName: "Test Mac"))
        await #expect(throws: AgentActivitySourceError.unsupported(op)) { try await source.perform(op) }
        let requests = AgentActivityRequests(model: AgentActivityModel(source: source), source: source)
        let reply = await requests.reply(to: "perform", params: parameters(op))
        #expect(reply["ok"] as? Bool == false)
        #expect((reply["error"] as? [String: String])?["userMessage"]?.isEmpty == false)
        #expect(requests.model.lastOperationError != nil)
        #expect(requests.model.watching.isEmpty)
    }

    private func parameters(_ op: AgentActivityUserOp) -> [String: Any] {
        switch op {
        case .export: ["op": "export", "session": "s"]
        case .openAgent: ["op": "openAgent", "session": "s"]
        case .openTarget: ["op": "openTarget", "session": "s"]
        case .stopAll: ["op": "stopAll", "machine": "local"]
        default: ["op": "watch", "session": "s", "on": true]
        }
    }
}

@MainActor @Observable
private final class HelperConnection {
    var value: AgentActivitySocketSource.Configuration?
}
