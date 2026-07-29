import CmuxCore
import CmuxFoundation
import CmuxRemoteWorkspace
import Darwin
import Foundation
import Testing
@testable import CmuxRemoteSession

@MainActor
@Suite("Native SSH ownership-gated recovery")
struct NativeSSHControlMasterOwnershipRecoveryTests {
    @Test("A live foreign owner prevents inherited-forward recovery")
    func foreignOwnerFailsClosed() {
        let controlPath =
            "/tmp/cmux-ssh-501-0123456789abcdef0123456789abcdef01234567"
        let broker = NativeSSHConnectionBroker(
            sharingOptions: SSHConnectionSharingOptions(userID: 501),
            clock: RecordingImmediateClock(),
            jitterMilliseconds: { 200 },
            cleanupLauncher: { _ in },
            controlMasterOwnershipRegistry:
                DenyingControlMasterOwnershipRegistry()
        )
        _ = broker.retainWorkspace(WorkspaceRemoteConfiguration(
            destination: "alice@example.test",
            port: nil,
            identityFile: nil,
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=\(controlPath)",
            ],
            localProxyPort: nil,
            relayPort: 64_001,
            relayID: "relay-id",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux-test.sock",
            ownerWorkspaceID: UUID(),
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-test"
        ))

        #expect(
            broker.beginReverseForwardRecovery(
                controlPath: controlPath
            ) == nil
        )
    }

    @Test("Foreground authentication hands ownership to the workspace without a gap")
    func foregroundAuthenticationOwnershipHandoff() throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-control-handoff-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let sharingOptions = SSHConnectionSharingOptions(
            userID: Int(getuid()),
            authenticationLockDirectoryPath: scratchDirectory.path
        )
        let firstRegistry = NativeSSHControlMasterOwnershipRegistry(
            sharingOptions: sharingOptions
        )
        let secondRegistry = NativeSSHControlMasterOwnershipRegistry(
            sharingOptions: sharingOptions
        )
        let broker = NativeSSHConnectionBroker(
            sharingOptions: sharingOptions,
            clock: SystemRemoteProxyRetryClock(),
            jitterMilliseconds: { 200 },
            cleanupLauncher: { _ in },
            controlMasterOwnershipRegistry: firstRegistry
        )
        let ownerWorkspaceID = UUID()
        let controlPath =
            "/tmp/cmux-ssh-\(getuid())-" +
            "0123456789abcdef0123456789abcdef01234567"
        let handoff = try #require(
            broker.beginControlMasterAdoption(
                controlPath: controlPath,
                ownerWorkspaceID: ownerWorkspaceID
            )
        )
        #expect(secondRegistry.beginRecovery(controlPath: controlPath) == nil)

        let configuration = broker.retainWorkspace(
            WorkspaceRemoteConfiguration(
                destination: "alice@example.test",
                port: nil,
                identityFile: nil,
                sshOptions: [
                    "ControlMaster=auto",
                    "ControlPersist=600",
                    "ControlPath=\(controlPath)",
                ],
                localProxyPort: nil,
                relayPort: 64_001,
                relayID: "relay-id",
                relayToken: String(repeating: "a", count: 64),
                localSocketPath: "/tmp/cmux-test.sock",
                ownerWorkspaceID: ownerWorkspaceID,
                terminalStartupCommand: nil,
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "ssh-test"
            )
        )
        #expect(broker.completeControlMasterAdoption(
            handoff,
            configuration: configuration
        ))
        #expect(secondRegistry.beginRecovery(controlPath: controlPath) == nil)

        broker.releaseWorkspace(configuration)
        let authorization = try #require(
            secondRegistry.beginRecovery(controlPath: controlPath)
        )
        authorization.release()
    }
}

private final class DenyingControlMasterOwnershipRegistry:
    NativeSSHControlMasterOwnershipTracking,
    Sendable
{
    func retain(
        controlPath: String,
        lease: NativeSSHControlMasterLeaseIdentity
    ) -> Bool {
        true
    }

    func release(lease: NativeSSHControlMasterLeaseIdentity) {}

    func beginRecovery(
        controlPath: String
    ) -> NativeSSHControlMasterExclusiveUseAuthorization? {
        nil
    }

    func beginCleanup(
        controlPath: String
    ) -> NativeSSHControlMasterExclusiveUseAuthorization? {
        nil
    }
}
