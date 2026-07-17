import Foundation
import Testing
@testable import CmuxFoundation

@Suite("SSH connection-sharing options")
struct SSHConnectionSharingOptionsTests {
    private let lockDirectory = URL(fileURLWithPath: "/private/var/folders/cmux-tests", isDirectory: true)
    private var options: SSHConnectionSharingOptions {
        SSHConnectionSharingOptions(userID: 501, authenticationLockDirectoryPath: lockDirectory.path)
    }

    @Test("Default control path is stable across workspace relay identities")
    func stableDefaultControlPath() {
        let first = options.mergingDefaults(into: ["StrictHostKeyChecking=accept-new"])
        let second = options.mergingDefaults(into: ["StrictHostKeyChecking=accept-new"])

        #expect(first == second)
        #expect(first.contains("ControlMaster=auto"))
        #expect(first.contains("ControlPersist=600"))
        #expect(first.contains("ControlPath=/tmp/cmux-ssh-501-%C"))
        #expect(!first.contains { $0.contains("64001-%C") })
    }

    @Test("Legacy relay-scoped cmux paths migrate to the host-stable path")
    func migratesLegacyRelayPath() {
        let merged = options.mergingDefaults(into: [
            "ControlMaster=auto",
            "ControlPath=/tmp/cmux-ssh-501-64001-%C",
            "ControlPersist=45",
        ])

        #expect(merged == [
            "ControlMaster=auto",
            "ControlPath=/tmp/cmux-ssh-501-%C",
            "ControlPersist=45",
        ])
    }

    @Test("Resolved legacy relay-scoped paths remain cmux-owned and migrate")
    func migratesResolvedLegacyRelayPath() {
        let legacyPath = "/tmp/cmux-ssh-501-64001-0123456789abcdef0123456789abcdef01234567"
        let supplied = [
            "ControlMaster=auto",
            "ControlPath=\(legacyPath)",
            "ControlPersist=45",
        ]

        #expect(options.cmuxOwnedControlPath(in: supplied) == legacyPath)
        #expect(options.mergingDefaults(into: supplied) == [
            "ControlMaster=auto",
            "ControlPath=/tmp/cmux-ssh-501-%C",
            "ControlPersist=45",
        ])
    }

    @Test("Caller-provided control settings remain authoritative")
    func preservesCustomControlSettings() {
        let supplied = [
            "ControlMaster=autoask",
            "ControlPath=~/.ssh/cmux-custom-%C",
            "ControlPersist=23",
        ]

        #expect(options.mergingDefaults(into: supplied) == supplied)
        #expect(options.cmuxOwnedControlPath(in: supplied) == nil)
    }

    @Test("Effective custom ssh_config control settings replace cmux defaults")
    func preservesResolvedSSHConfigSettings() {
        let output = """
        user alice
        hostname example.test
        port 22
        controlmaster auto
        controlpath /Users/alice/.ssh/control-a1b2
        controlpersist 90
        """
        let configured = options.userConfiguredControlOptions(fromSSHConfigOutput: output)
        let merged = options.mergingDefaults(
            into: ["StrictHostKeyChecking=accept-new"],
            userConfiguredControlOptions: configured
        )

        #expect(merged == [
            "StrictHostKeyChecking=accept-new",
            "ControlMaster=auto",
            "ControlPath=/Users/alice/.ssh/control-a1b2",
            "ControlPersist=90",
        ])
        #expect(options.cmuxOwnedControlPath(in: merged) == nil)
    }

    @Test("OpenSSH's default ssh_config output still enables cmux sharing")
    func ignoresResolvedOpenSSHDefaults() {
        let output = """
        user alice
        hostname example.test
        port 22
        controlmaster false
        controlpersist no
        """
        let configured = options.userConfiguredControlOptions(fromSSHConfigOutput: output)

        #expect(configured == nil)
        #expect(options.mergingDefaults(
            into: [],
            userConfiguredControlOptions: configured
        ).contains("ControlPath=/tmp/cmux-ssh-501-%C"))
    }

    @Test("Explicit CLI control options win per key over resolved ssh_config settings")
    func explicitOptionsWinOverResolvedConfiguration() {
        let configured = [
            "ControlMaster=auto",
            "ControlPath=/Users/alice/.ssh/configured-%C",
            "ControlPersist=90",
        ]

        #expect(options.mergingDefaults(
            into: ["ControlMaster=no"],
            userConfiguredControlOptions: configured
        ) == [
            "ControlMaster=no",
            "ControlPath=/Users/alice/.ssh/configured-%C",
            "ControlPersist=90",
        ])
    }

    @Test("Partial CLI control options preserve remaining ssh_config settings")
    func partialOptionsPreserveResolvedConfiguration() {
        let configured = [
            "ControlMaster=no",
            "ControlPath=none",
            "ControlPersist=10",
        ]

        #expect(options.mergingDefaults(
            into: ["ControlPersist=10"],
            userConfiguredControlOptions: configured
        ) == [
            "ControlPersist=10",
            "ControlMaster=no",
            "ControlPath=none",
        ])
    }

    @Test("An explicitly disabled master gets no sharing defaults")
    func preservesDisabledControlMaster() {
        let supplied = ["ControlMaster=no", "ForwardAgent=yes"]

        #expect(options.mergingDefaults(into: supplied) == supplied)
        #expect(options.cmuxOwnedControlPath(in: [
            "ControlMaster=no",
            "ControlPath=/tmp/cmux-ssh-501-%C",
        ]) == nil)
    }

    @Test("Only enabled cmux-owned paths create an authentication lock")
    func authenticationLockRequiresOwnedPath() {
        let owned = options.mergingDefaults(into: [])
        let resolvedOwned = [
            "ControlMaster=auto",
            "ControlPath=/tmp/cmux-ssh-501-0123456789abcdef0123456789abcdef01234567",
            "ControlPersist=600",
        ]
        let custom = [
            "ControlMaster=auto",
            "ControlPath=~/.ssh/custom-%C",
            "ControlPersist=600",
        ]

        let first = options.foregroundAuthenticationLockPath(
            destination: "alice@example.test",
            port: 2222,
            options: owned
        )
        let second = options.foregroundAuthenticationLockPath(
            destination: "alice@example.test",
            port: 2222,
            options: owned
        )
        #expect(first == second)
        #expect(first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } == lockDirectory)
        #expect(first.map { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("cmux-ssh-501-auth-") } == true)
        let resolvedLock = options.foregroundAuthenticationLockPath(
            destination: "ssh-alias",
            port: nil,
            options: resolvedOwned
        )
        #expect(resolvedLock.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } == lockDirectory)
        #expect(resolvedLock.map { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("cmux-ssh-501-auth-") } == true)
        #expect(resolvedLock != first)
        #expect(options.cmuxOwnedControlPath(in: resolvedOwned) == String(
            resolvedOwned[1].dropFirst("ControlPath=".count)
        ))
        #expect(options.foregroundAuthenticationLockPath(
            destination: "alice@example.test",
            port: 2222,
            options: custom
        ) == nil)
    }

    @Test("Stale-socket preflight is scoped to the cmux-owned path")
    func preflightRequiresOwnedPath() {
        let owned = options.mergingDefaults(into: [])
        let function = options.controlPathPreflightShellFunction(
            sshArguments: ["ssh", "-p", "2222"],
            destination: "alice@example.test",
            options: owned
        )

        #expect(function?.contains("ssh -p 2222 -G alice@example.test") == true)
        #expect(function?.contains("/tmp/cmux-ssh-501-*") == true)
        #expect(function?.contains("-O check alice@example.test") == true)
        #expect(options.controlPathPreflightShellFunction(
            sshArguments: ["ssh"],
            destination: "alice@example.test",
            options: ["ControlMaster=auto", "ControlPath=~/.ssh/custom-%C"]
        ) == nil)
    }
}
