import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The launch marks (`debug.timings`) keep the first time of each name. A relaunch makes the New Tab
/// spare's page beside the restored chat's, and the spare connected first, so `agent_pane.transport_open`
/// read as the chat's was the spare's time: the relaunch check reported a 1.8 s "transport_open ->
/// painted" span on the chat that does not exist (cmuxterm-hq#7149). The spare's marks are its own.
@Suite(.serialized)
@MainActor
struct AgentPaneLaunchMarkPaneTests {
    /// The App's receiver: the first time of each name.
    final class FirstMarks: @unchecked Sendable {
        // Safety: written and read on the main actor only (the receiver below hops there).
        private(set) var first: [String: Date] = [:]
        func keep(_ name: String, _ date: Date) { if first[name] == nil { first[name] = date } }
    }

    @Test(.timeLimit(.minutes(1))) func theRestoredChatsTransportOpenIsItsOwnNotTheSparesBeforeIt() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let timings = AgentPaneLaunchTimings()
        let marks = FirstMarks()
        timings.install { name, date in MainActor.assumeIsolated { marks.keep(name, date) } }
        let connection = AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil)

        // The New Tab spare's page connects first.
        let spare = AgentPaneModel(host: MockAgentPaneHost(), newTab: AgentPaneNewTab(kind: .agent))
        spare.transport.launchTimings = timings
        _ = try await spare.transport.open(connection)
        let chatOpens = Date()

        // Then the restored chat's.
        let chat = AgentPaneModel(host: MockAgentPaneHost(), sessionId: "restored")
        chat.transport.launchTimings = timings
        _ = try await chat.transport.open(connection)

        let opened = try #require(marks.first["agent_pane.transport_open"], "the chat's connection made no transport_open mark")
        #expect(opened >= chatOpens, "transport_open is the spare's time, \(chatOpens.timeIntervalSince(opened) * 1000) ms before the chat's open")
        let started = try #require(marks.first["agent_pane.transport_open_start"])
        #expect(started >= chatOpens, "transport_open_start is the spare's time")
        #expect(marks.first["agent_pane.newtab_transport_open"] != nil, "the spare's own connection has no mark of its own")
    }
}
