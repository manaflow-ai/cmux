import AppKit
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// "i guess is team? it's kinda hard to realize tho" (Leo, 2026-11-09): the composer's Cloud row
/// names the active team. A switch of team tells each page of the App's machines at once, so the
/// row never keeps the old team's name until the next list read.
@Suite(.serialized)
@MainActor
struct AgentPaneCloudTeamChangeTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func view(_ machines: AgentPaneCloudMachines) throws -> AgentPaneView {
        _ = NSApplication.shared
        let model = AgentPaneModel(host: NoHost())
        model.cloudMachines = machines
        return try #require(AgentPaneView(model: model, source: .bundled(URL(filePath: "/dev/null"))))
    }

    @Test func aTeamChangeTellsThePagesOfItsMachinesOnly() throws {
        let machines = AgentPaneCloudMachines(), other = AgentPaneCloudMachines()
        let view = try Self.view(machines)
        var scripts: [String] = []
        view.evaluateScript = { scripts.append($0) }

        other.publishTeamChange()
        #expect(!scripts.contains(AgentPaneCloudMachines.teamChangeScript), "another machines' team change reached the page")

        machines.publishTeamChange()
        #expect(scripts.filter { $0 == AgentPaneCloudMachines.teamChangeScript }.count == 1)

        // Handed again (a reused pane), it still hears each change once.
        view.model.cloudMachines = machines
        machines.publishTeamChange()
        #expect(scripts.filter { $0 == AgentPaneCloudMachines.teamChangeScript }.count == 2)
        #expect(AgentPaneCloudMachines.teamChangeScript.contains("cmux-cloud-team-change"))
    }

    @Test func aNewTeamWatchCancelsTheOldOne() {
        let machines = AgentPaneCloudMachines()
        let first = Task<Void, Never> { while !Task.isCancelled { await Task.yield() } }
        machines.teamWatch = first
        machines.teamWatch = Task {}
        #expect(first.isCancelled)
        machines.teamWatch = nil
    }
}
