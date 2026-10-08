import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// keep-on-quit keeps an older cmux-tui daemon running across an app update, so the new app can
/// meet a daemon without `workspace.agent_folder.set` (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE).
/// Choose Folder… then says to restart the background service: never a crash, never silence.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AgentFolderVersionSkewTests {
    nonisolated static let unknownVariant = #"{"code":"validation.invalid","message":"invalid request envelope","details":{"error":"unknown variant `workspace.agent_folder.set`, expected one of `workspace.update`"},"retryable":false}"#

    func services(_ daemon: StateDaemon) async throws -> AppServices {
        try await StateMutationRoutingTests().services(daemon)
    }

    @Test func aDaemonWithoutTheCapabilityGetsNoRequestAndTheRestartMessage() async throws {
        let daemon = try StateDaemon(state: "{}")
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { services.daemon.shutdownConnection() }
        let result = await AgentTabStore.saveAgentFolder("/tmp", workspace: ResourceID(rawValue: "ws_w"), on: services.daemon)
        #expect(result == .unavailable(AgentPaneFolderChoice.restartServiceMessage))
        #expect(!daemon.operations.contains("workspace.agent_folder.set"))
    }

    @Test func anUnknownOperationReplyGetsTheRestartMessage() async throws {
        let daemon = try StateDaemon(state: "{}", capabilities: [DaemonCapabilities.shared.workspaceAgentFolder],
                                     failure: { $0 == "workspace.agent_folder.set" ? Self.unknownVariant : nil })
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { services.daemon.shutdownConnection() }
        let result = await AgentTabStore.saveAgentFolder("/tmp", workspace: ResourceID(rawValue: "ws_w"), on: services.daemon)
        #expect(result == .unavailable(AgentPaneFolderChoice.restartServiceMessage))
        #expect(daemon.operations.contains("workspace.agent_folder.set"))
    }

    @Test func anotherFailureSaysTheFolderWasNotSaved() async throws {
        let refused = #"{"code":"validation.invalid","message":"path must name a folder","details":{"field":"path"},"retryable":false}"#
        let daemon = try StateDaemon(state: "{}", capabilities: [DaemonCapabilities.shared.workspaceAgentFolder],
                                     failure: { $0 == "workspace.agent_folder.set" ? refused : nil })
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { services.daemon.shutdownConnection() }
        let result = await AgentTabStore.saveAgentFolder("/tmp", workspace: ResourceID(rawValue: "ws_w"), on: services.daemon)
        #expect(result == .unavailable(AgentPaneFolderChoice.notSavedMessage))
    }

    @Test func aCurrentDaemonSavesTheFolder() async throws {
        let daemon = try StateDaemon(state: "{}", capabilities: [DaemonCapabilities.shared.workspaceAgentFolder])
        defer { daemon.stop() }
        let services = try await services(daemon)
        defer { services.daemon.shutdownConnection() }
        let result = await AgentTabStore.saveAgentFolder("/tmp", workspace: ResourceID(rawValue: "ws_w"), on: services.daemon)
        #expect(result == .chosen("/tmp"))
        #expect(daemon.params(of: "workspace.agent_folder.set")?["path"] == .string("/tmp"))
    }
}
