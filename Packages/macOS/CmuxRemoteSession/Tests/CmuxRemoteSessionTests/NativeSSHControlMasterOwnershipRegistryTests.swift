import CmuxFoundation
import Darwin
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Native SSH cross-process master ownership")
struct NativeSSHControlMasterOwnershipRegistryTests {
    @Test("A live sibling process blocks recovery until it releases its lease")
    func liveSiblingBlocksRecovery() throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-control-owner-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let sharingOptions = SSHConnectionSharingOptions(
            userID: Int(getuid()),
            authenticationLockDirectoryPath: scratchDirectory.path
        )
        let controlPath = resolvedControlPath(userID: Int(getuid()))
        let first = NativeSSHControlMasterOwnershipRegistry(
            sharingOptions: sharingOptions
        )
        let second = NativeSSHControlMasterOwnershipRegistry(
            sharingOptions: sharingOptions
        )
        let firstLease = NativeSSHControlMasterLeaseIdentity(
            ownerWorkspaceID: UUID(),
            generation: UUID()
        )
        let secondLease = NativeSSHControlMasterLeaseIdentity(
            ownerWorkspaceID: UUID(),
            generation: UUID()
        )

        #expect(first.retain(
            controlPath: controlPath,
            lease: firstLease
        ))
        #expect(second.retain(
            controlPath: controlPath,
            lease: secondLease
        ))
        #expect(first.beginRecovery(controlPath: controlPath) == nil)

        second.release(lease: secondLease)
        let authorization = try #require(
            first.beginRecovery(controlPath: controlPath)
        )
        #expect(!second.retain(
            controlPath: controlPath,
            lease: secondLease
        ))
        authorization.release()
        #expect(second.retain(
            controlPath: controlPath,
            lease: secondLease
        ))
    }

    @Test("Resolved authentication blocks recovery across different aliases")
    func resolvedAuthenticationBlocksRecovery() throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-control-auth-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let sharingOptions = SSHConnectionSharingOptions(
            userID: Int(getuid()),
            authenticationLockDirectoryPath: scratchDirectory.path
        )
        let controlPath = resolvedControlPath(userID: Int(getuid()))
        let registry = NativeSSHControlMasterOwnershipRegistry(
            sharingOptions: sharingOptions
        )
        let lease = NativeSSHControlMasterLeaseIdentity(
            ownerWorkspaceID: UUID(),
            generation: UUID()
        )
        let authenticationPath = try #require(
            sharingOptions.resolvedControlMasterAuthenticationLockPath(
                controlPath: controlPath
            )
        )
        #expect(FileManager.default.createFile(
            atPath: authenticationPath,
            contents: Data()
        ))
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-fc",
            """
            zmodload zsh/system || exit 1
            zsystem flock -t 2 -e -f cmux_test_auth_fd "$1" || exit 2
            print 'ready'
            IFS= read -r _ || true
            exit 0
            """,
            "cmux-auth-lock",
            authenticationPath,
        ]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }
        let ready = stdout.fileHandleForReading.readData(ofLength: 6)
        #expect(String(decoding: ready, as: UTF8.self) == "ready\n")
        #expect(registry.retain(controlPath: controlPath, lease: lease))
        #expect(registry.beginRecovery(controlPath: controlPath) == nil)

        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let authorization = try #require(
            registry.beginRecovery(controlPath: controlPath)
        )
        authorization.release()
    }

    @Test("Ordinary cleanup never overrides a live local lease")
    func cleanupRespectsLocalLease() throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-control-cleanup-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let registry = NativeSSHControlMasterOwnershipRegistry(
            sharingOptions: SSHConnectionSharingOptions(
                userID: Int(getuid()),
                authenticationLockDirectoryPath: scratchDirectory.path
            )
        )
        let controlPath = resolvedControlPath(userID: Int(getuid()))
        let lease = NativeSSHControlMasterLeaseIdentity(
            ownerWorkspaceID: UUID(),
            generation: UUID()
        )

        #expect(registry.retain(controlPath: controlPath, lease: lease))
        #expect(registry.beginCleanup(controlPath: controlPath) == nil)

        let recovery = try #require(
            registry.beginRecovery(controlPath: controlPath)
        )
        recovery.release()
        #expect(registry.beginCleanup(controlPath: controlPath) == nil)

        registry.release(lease: lease)
        let cleanup = try #require(
            registry.beginCleanup(controlPath: controlPath)
        )
        cleanup.release()
    }

    @Test("A rejected local operation preserves the active authentication lock")
    func rejectedOperationPreservesAuthenticationLock() throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-control-exclusive-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let sharingOptions = SSHConnectionSharingOptions(
            userID: Int(getuid()),
            authenticationLockDirectoryPath: scratchDirectory.path
        )
        let first = NativeSSHControlMasterOwnershipRegistry(
            sharingOptions: sharingOptions
        )
        let second = NativeSSHControlMasterOwnershipRegistry(
            sharingOptions: sharingOptions
        )
        let controlPath = resolvedControlPath(userID: Int(getuid()))
        let authenticationPath = try #require(
            sharingOptions.resolvedControlMasterAuthenticationLockPath(
                controlPath: controlPath
            )
        )

        let recovery = try #require(
            first.beginRecovery(controlPath: controlPath)
        )
        #expect(second.beginCleanup(controlPath: controlPath) == nil)
        #expect(
            try childCanAcquireAuthenticationLock(
                at: authenticationPath
            ) == false
        )

        recovery.release()
        let cleanup = try #require(
            second.beginCleanup(controlPath: controlPath)
        )
        cleanup.release()
        #expect(
            try childCanAcquireAuthenticationLock(
                at: authenticationPath
            )
        )
    }

    @Test("Authorization deinit restores the process shared lease")
    func authorizationDeinitRestoresSharedLease() throws {
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-control-auth-deinit-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }
        let sharingOptions = SSHConnectionSharingOptions(
            userID: Int(getuid()),
            authenticationLockDirectoryPath: scratchDirectory.path
        )
        let controlPath = resolvedControlPath(userID: Int(getuid()))
        let first = NativeSSHControlMasterOwnershipRegistry(
            sharingOptions: sharingOptions
        )
        let second = NativeSSHControlMasterOwnershipRegistry(
            sharingOptions: sharingOptions
        )
        let lease = NativeSSHControlMasterLeaseIdentity(
            ownerWorkspaceID: UUID(),
            generation: UUID()
        )
        #expect(first.retain(controlPath: controlPath, lease: lease))

        var authorization = first.beginRecovery(controlPath: controlPath)
        #expect(authorization != nil)
        authorization = nil

        #expect(second.beginRecovery(controlPath: controlPath) == nil)
        first.release(lease: lease)
        let secondAuthorization = try #require(
            second.beginRecovery(controlPath: controlPath)
        )
        secondAuthorization.release()
    }

    private func resolvedControlPath(userID: Int) -> String {
        "/tmp/cmux-ssh-\(userID)-0123456789abcdef0123456789abcdef01234567"
    }

    private func childCanAcquireAuthenticationLock(
        at path: String
    ) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-fc",
            """
            zmodload zsh/system || exit 1
            zsystem flock -t 0 -e "$1"
            """,
            "cmux-auth-lock-probe",
            path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
