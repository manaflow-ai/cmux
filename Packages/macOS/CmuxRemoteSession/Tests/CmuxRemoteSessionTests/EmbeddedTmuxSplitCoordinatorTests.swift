import CmuxCore
import CmuxFoundation
import Foundation
import Testing
@testable import CmuxRemoteSession

@MainActor
struct EmbeddedTmuxSplitCoordinatorTests {
    @Test func createsOnePaneInTheExactPersistedSession() async throws {
        let commands = EmbeddedTmuxTestCommands()
        let coordinator = EmbeddedTmuxSplitCoordinator(commands: commands)
        let id = try #require(coordinator.start(
            configuration: configuration(), vertical: false, insertBefore: true, focus: false
        ))
        #expect(await coordinator.completion(for: id) == .succeeded)
        #expect(coordinator.paneID == "%17")
        let calls = await commands.calls
        #expect(calls.count == 1)
        let invocation = try #require(calls.first)
        #expect(invocation.first == "/usr/bin/ssh")
        #expect(invocation.contains("2222"))
        #expect(invocation.contains("ProxyJump=jump-host"))
        #expect(invocation.contains("ControlPath=/tmp/issue-11517-master"))
        #expect(invocation.contains("BatchMode=yes"))
        #expect(invocation.contains("RequestTTY=no"))
        #expect(!invocation.contains("RequestTTY=force"))
        let command = try #require(invocation.last)
        // Assert the external command's arguments, including exact-session targeting
        // and detached creation; these decide which live remote pane is mutated.
        #expect(command.contains("split-window"))
        #expect(command.contains("=work session:"))
        #expect(command.contains("-h"))
        #expect(command.contains("-b"))
        #expect(command.contains("-d"))
    }

    @Test func aPendingSplitIsNeverSubmittedTwice() async throws {
        let commands = EmbeddedTmuxTestCommands(suspended: true)
        let coordinator = EmbeddedTmuxSplitCoordinator(commands: commands)
        let id = try #require(coordinator.start(
            configuration: configuration(), vertical: true, insertBefore: false, focus: true
        ))
        await commands.waitForStart()
        #expect(coordinator.start(
            configuration: configuration(), vertical: true, insertBefore: false, focus: true
        ) == nil)
        await commands.complete()
        #expect(await coordinator.completion(for: id) == .succeeded)
        #expect(await commands.calls.count == 1)
    }

    @Test func failedManagementCommandDoesNotRetry() async throws {
        let commands = EmbeddedTmuxTestCommands(stdout: nil, status: 255)
        let coordinator = EmbeddedTmuxSplitCoordinator(commands: commands)
        let id = try #require(coordinator.start(
            configuration: configuration(), vertical: true, insertBefore: false, focus: true
        ))
        #expect(await coordinator.completion(for: id) == .failed)
        #expect(coordinator.paneID == nil)
        #expect(await commands.calls.count == 1)
    }

    @Test func reconnectDiscardsLateCompletionFromTheOldConnection() async throws {
        let commands = EmbeddedTmuxTestCommands(suspended: true)
        let coordinator = EmbeddedTmuxSplitCoordinator(commands: commands)
        let id = try #require(coordinator.start(
            configuration: configuration(), vertical: true, insertBefore: false, focus: true
        ))
        await commands.waitForStart()
        coordinator.reset()
        await commands.complete()
        #expect(await coordinator.completion(for: id) == nil)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.requestID == nil)
        #expect(coordinator.paneID == nil)
    }

    private func configuration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            terminalTransport: .mosh,
            terminalProfile: WorkspaceRemoteTerminalProfile(kind: .tmux, tmuxSessionName: "work session")!,
            destination: "issue-11517.invalid", port: 2222, identityFile: "/tmp/issue-11517-key",
            sshOptions: ["ProxyJump=jump-host", "ControlPath=/tmp/issue-11517-master", "RequestTTY=force"],
            localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil
        )
    }
}
