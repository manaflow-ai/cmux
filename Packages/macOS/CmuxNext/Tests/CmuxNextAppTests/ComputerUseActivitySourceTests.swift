@testable import CmuxNextAgentActivity
import CmuxNextWakeups
import Foundation
import Observation
import Testing

@MainActor
struct ComputerUseActivitySourceTests {
    /// Runs the rig's frames (the configuration observation's flush) until the source reports a change.
    private static func frames(_ rig: MainDeadlineRig, until done: () -> Bool) async throws {
        for _ in 0..<250 where !done() {
            rig.frame()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func sourceFollowsTheHelpersSocketAndFreshTokens() async throws {
        let settings = HelperConnection()
        let rig = MainDeadlineRig()
        var sent: [AgentActivitySocketSource.Configuration] = []
        let source = AgentActivitySocketSource(configuration: { settings.value }, deadlines: rig.deadlines,
                                               send: { configuration, method, args in
            #expect(method == "activity_session_pause")
            #expect(args["id"] as? String == "s")
            sent.append(configuration)
            return [:]
        })
        // The helper's socket and tokens reach the source through its `background` configuration observation,
        // which flushes on the rig's frames.
        var changes = 0
        source.start { _ in changes += 1 }
        defer { source.stop() }
        await #expect(throws: AgentActivitySourceError.closed) { try await source.perform(.pause(session: "s")) }
        #expect(sent.isEmpty)
        let first = AgentActivitySocketSource.Configuration(socketPath: "/missing/first/cua.sock", authToken: "agent1",
                                                            hostAuthToken: "host1", machineName: "Test Mac")
        var seen = changes
        settings.value = first
        try await Self.frames(rig) { changes > seen }
        #expect(changes > seen, "the source did not follow the helper's new configuration")
        try await source.perform(.pause(session: "s"))
        #expect(sent == [first])
        let restarted = AgentActivitySocketSource.Configuration(socketPath: first.socketPath, authToken: "agent2",
                                                                hostAuthToken: "host2", machineName: "Test Mac")
        seen = changes
        settings.value = restarted
        try await Self.frames(rig) { changes > seen }
        #expect(changes > seen, "the source did not follow the helper's new configuration")
        try await source.perform(.pause(session: "s"))
        #expect(sent == [first, restarted])
        seen = changes
        settings.value = nil
        try await Self.frames(rig) { changes > seen }
        #expect(changes > seen, "the source did not follow the helper's new configuration")
        await #expect(throws: AgentActivitySourceError.closed) { try await source.perform(.pause(session: "s")) }
        #expect(sent == [first, restarted])
    }

    @Test(arguments: [AgentActivityUserOp.export(session: "s"), .openAgent(session: "s"), .openTarget(session: "s"),
                      .stopAll(machine: "local"), .watch(session: "s", on: true)])
    func unsupportedOperationsReportAnError(_ op: AgentActivityUserOp) async {
        let rig = MainDeadlineRig()
        let source = AgentActivitySocketSource(configuration: .init(socketPath: "/missing/cua.sock", machineName: "Test Mac"),
                                               deadlines: rig.deadlines)
        await #expect(throws: AgentActivitySourceError.unsupported(op)) { try await source.perform(op) }
        let requests = AgentActivityRequests(model: AgentActivityModel(source: source, mainWork: rig.work), source: source)
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
