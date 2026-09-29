import Foundation
import Testing
@testable import CmuxFoundation

@Suite("SSH connection-sharing options")
struct SSHConnectionSharingOptionsTests {
    private let lockDirectory = URL(fileURLWithPath: "/private/var/folders/cmux-tests", isDirectory: true)
    private let socketDirectory = "/Users/alice/.cmux/ssh"
    private var options: SSHConnectionSharingOptions {
        SSHConnectionSharingOptions(
            userID: 501,
            controlSocketDirectoryPath: socketDirectory,
            authenticationLockDirectoryPath: lockDirectory.path
        )
    }

    @Test("Default control path is stable across workspace relay identities")
    func stableDefaultControlPath() {
        let first = options.mergingDefaults(into: ["RequestTTY=auto"])
        let second = options.mergingDefaults(into: ["RequestTTY=auto"])

        #expect(first == second)
        #expect(first.contains("ControlMaster=auto"))
        #expect(first.contains("ControlPersist=600"))
        #expect(first.contains("ControlPath=/Users/alice/.cmux/ssh/%C"))
        #expect(!first.contains { $0.contains("64001-%C") })
    }

    @Test("Relay-scoped paths an older cmux used in /tmp migrate to the private host-stable path")
    func migratesLegacyRelayPath() {
        let merged = options.mergingDefaults(into: [
            "ControlMaster=auto",
            "ControlPath=/tmp/cmux-ssh-501-64001-%C",
            "ControlPersist=45",
        ])

        #expect(merged == [
            "ControlMaster=auto",
            "ControlPath=/Users/alice/.cmux/ssh/%C",
            "ControlPersist=45",
        ])
    }

    @Test("Resolved relay-scoped /tmp paths are not cmux-owned and migrate")
    func migratesResolvedLegacyRelayPath() {
        let legacyPath = "/tmp/cmux-ssh-501-64001-0123456789abcdef0123456789abcdef01234567"
        let supplied = [
            "ControlMaster=auto",
            "ControlPath=\(legacyPath)",
            "ControlPersist=45",
        ]

        #expect(options.cmuxOwnedControlPath(in: supplied) == nil)
        #expect(options.mergingDefaults(into: supplied) == [
            "ControlMaster=auto",
            "ControlPath=/Users/alice/.cmux/ssh/%C",
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

    @Test("Ownership follows OpenSSH's first repeated ControlPath")
    func ownershipUsesFirstControlPath() {
        let customFirst = [
            "ControlMaster=auto",
            "ControlPath=~/.ssh/custom-%C",
            "ControlPath=/Users/alice/.cmux/ssh/%C",
        ]
        let ownedFirst = [
            "ControlMaster=auto",
            "ControlPath=/Users/alice/.cmux/ssh/%C",
            "ControlPath=~/.ssh/custom-%C",
        ]

        #expect(options.cmuxOwnedControlPath(in: customFirst) == nil)
        #expect(
            options.cmuxOwnedControlPath(in: ownedFirst)
                == "/Users/alice/.cmux/ssh/%C"
        )
    }

    @Test("Shared option parsing follows OpenSSH's first-value rule")
    func optionResolverUsesFirstValue() {
        let resolver = SSHAgentSocketResolver()

        #expect(resolver.optionValue(
            named: "ControlMaster",
            in: [
                "ControlMaster=no",
                "ControlMaster=auto",
            ]
        ) == "no")
        #expect(resolver.optionValue(
            named: "ControlPersist",
            in: [
                "ControlPersist=600",
                "ControlPersist=no",
            ]
        ) == "600")
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

    @Test("Explicit route options disable cmux default sharing")
    func explicitRouteOptionsDoNotShareAHostStableSocket() {
        let merged = options.mergingDefaults(into: [
            "ProxyCommand=/usr/local/bin/broker %h %p",
            "IdentityFile=/Users/alice/.ssh/route-key",
            "HostKeyAlias=production",
        ])
        #expect(!merged.contains("ControlPath=/Users/alice/.cmux/ssh/%C"))
        #expect(!merged.contains("ControlMaster=auto"))
    }

    @Test("Host-key policy options disable default sharing")
    func hostKeyPolicyOptionsDoNotShareAHostStableSocket() {
        for option in [
            "StrictHostKeyChecking=no",
            "CheckHostIP=no",
            "VerifyHostKeyDNS=yes",
            "UpdateHostkeys=no",
            "KnownHostsCommand=/usr/local/bin/known-hosts %H %p",
            "RevokedHostKeys=/Users/alice/.ssh/revoked",
            "CASignatureAlgorithms=ssh-ed25519",
            "RequiredRSASize=3072",
            "KexAlgorithms=curve25519-sha256",
        ] {
            let merged = options.mergingDefaults(into: [option])
            #expect(!merged.contains("ControlPath=/Users/alice/.cmux/ssh/%C"), "\(option)")
            #expect(!merged.contains("ControlMaster=auto"), "\(option)")
        }
    }

    @Test("Route-specific ssh_config settings disable cmux default sharing")
    func routeSpecificConfigurationDoesNotShareAHostStableSocket() {
        let baseline = """
        controlmaster false
        controlpersist no
        proxycommand none
        identityfile none
        hostkeyalias none
        """
        let configured = """
        controlmaster false
        controlpersist no
        proxycommand /usr/local/bin/broker %h %p
        identityfile /Users/alice/.ssh/route-key
        hostkeyalias production
        """
        let resolved = options.userConfiguredControlOptions(
            fromSSHConfigOutput: configured,
            baselineSSHConfigOutput: baseline,
            explicitOptions: []
        )
        #expect(resolved?.contains("__cmux_route_sensitive=true") == true)
        let merged = options.mergingDefaults(into: [], userConfiguredControlOptions: resolved)
        #expect(merged.contains("ControlMaster=no"))
        #expect(merged.contains("ControlPath=none"))
        let remerged = options.mergingDefaults(into: merged)
        #expect(remerged == merged)
        #expect(!remerged.contains("ControlMaster=auto"))
        #expect(!remerged.contains("ControlPath=/Users/alice/.cmux/ssh/%C"))
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
        ).contains("ControlPath=/Users/alice/.cmux/ssh/%C"))
    }

    @Test("Supported OpenSSH normalization drives host opt-out detection")
    func detectsHostOptOutUsingRealOpenSSHNormalization() throws {
        let host = "cmux-normalization.invalid"
        let baseline = try resolvedSSHConfiguration(
            host: host,
            configurationFile: "/dev/null"
        )
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-normalization-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: configURL) }
        try """
        Host cmux-normalization.invalid
          ControlMaster no
          ControlPath none
          ControlPersist no
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let configured = try resolvedSSHConfiguration(
            host: host,
            configurationFile: configURL.path
        )

        // The supported macOS OpenSSH currently normalizes ControlMaster=no
        // to the same controlmaster=false value as its built-in default.
        // The product compares these exact ssh -G outputs, so this test owns
        // that resolver boundary instead of inventing distinct text.
        #expect(controlSettings(in: configured) == controlSettings(in: baseline))
        #expect(options.userConfiguredControlOptions(
            fromSSHConfigOutput: configured,
            baselineSSHConfigOutput: baseline,
            explicitOptions: []
        ) == nil)
    }

    @Test("A baseline that omits unset keys still reads as OpenSSH defaults")
    func baselineOmittingUnsetKeysMatchesDefaults() {
        let baseline = """
        controlmaster false
        controlpersist no
        """
        #expect(options.userConfiguredControlOptions(
            fromSSHConfigOutput: baseline,
            baselineSSHConfigOutput: baseline,
            explicitOptions: []
        ) == nil)
        let configured = """
        controlmaster false
        controlpath /Users/alice/.ssh/control-a1b2
        controlpersist no
        """
        #expect(options.userConfiguredControlOptions(
            fromSSHConfigOutput: configured,
            baselineSSHConfigOutput: baseline,
            explicitOptions: []
        ) == [
            "ControlMaster=false",
            "ControlPath=/Users/alice/.ssh/control-a1b2",
            "ControlPersist=no",
        ])
    }

    @Test("An explicit persistence flag does not import OpenSSH's disabled sharing defaults", arguments: [
        ("ControlPersist=0", "yes"),
        ("ControlPersist=10", "10"),
    ])
    func explicitPersistenceKeepsMissingSharingDefaults(option: String, resolvedValue: String) {
        let configured = options.userConfiguredControlOptions(
            fromSSHConfigOutput: """
            controlmaster false
            controlpath none
            controlpersist \(resolvedValue)
            """,
            explicitOptions: [option]
        )
        let merged = options.mergingDefaults(into: [option], userConfiguredControlOptions: configured)

        #expect(configured == nil)
        #expect(merged == [option, "ControlMaster=auto", "ControlPath=/Users/alice/.cmux/ssh/%C"])
        #expect(options.cmuxOwnedControlPath(in: merged) == "/Users/alice/.cmux/ssh/%C")
    }

    @Test("An explicit master flag does not import OpenSSH's absent control path")
    func explicitMasterKeepsMissingSharingDefaults() {
        let configured = options.userConfiguredControlOptions(
            fromSSHConfigOutput: """
            controlmaster auto
            controlpath none
            controlpersist no
            """,
            explicitOptions: ["ControlMaster=auto"]
        )
        let merged = options.mergingDefaults(
            into: ["ControlMaster=auto"],
            userConfiguredControlOptions: configured
        )

        #expect(configured == nil)
        #expect(merged == [
            "ControlMaster=auto",
            "ControlPersist=600",
            "ControlPath=/Users/alice/.cmux/ssh/%C",
        ])
    }

    @Test("Explicit persistence preserves independently configured host control settings", arguments: ["auto", "false"])
    func explicitPersistencePreservesCustomHostPath(controlMaster: String) {
        let configured = options.userConfiguredControlOptions(
            fromSSHConfigOutput: """
            controlmaster \(controlMaster)
            controlpath /Users/alice/.ssh/configured-%C
            controlpersist yes
            """,
            explicitOptions: ["ControlPersist=0"]
        )
        let merged = options.mergingDefaults(
            into: ["ControlPersist=0"],
            userConfiguredControlOptions: configured
        )

        #expect(merged == [
            "ControlPersist=0",
            "ControlMaster=\(controlMaster)",
            "ControlPath=/Users/alice/.ssh/configured-%C",
        ])
        #expect(options.cmuxOwnedControlPath(in: merged) == nil)
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
            "ControlPath=/Users/alice/.cmux/ssh/%C",
        ]) == nil)
    }

    private func resolvedSSHConfiguration(
        host: String,
        configurationFile: String
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", configurationFile, host]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private func controlSettings(in output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            if ["controlmaster", "controlpath", "controlpersist"].contains(key) {
                values[key] = String(parts[1])
            }
        }
        return values
    }

    @Test("Only enabled cmux-owned paths create an authentication lock")
    func authenticationLockRequiresOwnedPath() {
        let owned = options.mergingDefaults(into: [])
        let resolvedOwned = [
            "ControlMaster=auto",
            "ControlPath=/Users/alice/.cmux/ssh/0123456789abcdef0123456789abcdef01234567",
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
        let resolvedControlPath = String(
            resolvedOwned[1].dropFirst("ControlPath=".count)
        )
        #expect(options.cmuxOwnedControlPath(in: resolvedOwned) == resolvedControlPath)
        let aliasIndependentLock =
            options.resolvedControlMasterAuthenticationLockPath(
                controlPath: resolvedControlPath
            )
        #expect(aliasIndependentLock.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent()
        } == lockDirectory)
        #expect(aliasIndependentLock?.contains("resolved-auth") == true)
        #expect(options.resolvedControlMasterOwnershipLockPath(
            controlPath: resolvedControlPath
        )?.contains("-owner-") == true)
        #expect(options.resolvedControlMasterAuthenticationLockPath(
            controlPath: "/Users/alice/.cmux/ssh/%C"
        ) == nil)
        #expect(options.resolvedControlMasterOwnershipLockPath(
            controlPath: "~/.ssh/custom-control"
        ) == nil)
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

        #expect(function?.contains("ssh -p 2222 -G -- alice@example.test") == true)
        #expect(function?.contains("    '/Users/alice/.cmux/ssh'/\(String(repeating: "[0-9a-f]", count: 40)))") == true)
        #expect(function?.contains("-O check -- alice@example.test") == true)
        #expect(options.controlPathPreflightShellFunction(
            sshArguments: ["ssh"],
            destination: "alice@example.test",
            options: ["ControlMaster=auto", "ControlPath=~/.ssh/custom-%C"]
        ) == nil)
    }

    @Test("Without a private directory cmux adds no sharing defaults and drops a /tmp socket")
    func noPrivateDirectorySharesNothing() {
        let unshared = SSHConnectionSharingOptions(userID: 501, controlSocketDirectoryPath: nil)
        let supplied = ["ControlMaster=auto", "ControlPath=/tmp/cmux-ssh-501-%C"]

        #expect(unshared.defaultControlPath == nil)
        #expect(unshared.mergingDefaults(into: ["ForwardAgent=no"]) == ["ForwardAgent=no"])
        #expect(unshared.mergingDefaults(into: supplied) == ["ControlMaster=auto", "ControlPath=none"])
        #expect(unshared.mergingDefaults(into: ["ControlPath=~/.ssh/custom-%C"]) == ["ControlPath=~/.ssh/custom-%C"])
        #expect(unshared.cmuxOwnedControlPath(in: supplied) == nil)
        #expect(unshared.controlPathPreflightShellFunction(
            sshArguments: ["ssh"], destination: "alice@example.test", options: supplied
        ) == nil)
    }

    @Test("A directory OpenSSH would expand or that can't hold a socket shares nothing", arguments: [
        "relative/.cmux/ssh",
        "/Users/al ice/.cmux/ssh",
        "/Users/%u/.cmux/ssh",
        "/Users/${USER}/.cmux/ssh",
        "/Users/alice/.cmux/ssh/",
        "/Users/alice/.cmux/ssh\n",
        "/Users/" + String(repeating: "a", count: 29) + "/.cmux/ssh",
    ])
    func unusableDirectorySharesNothing(directory: String) {
        let unusable = SSHConnectionSharingOptions(userID: 501, controlSocketDirectoryPath: directory)

        #expect(unusable.controlSocketDirectoryPath == nil)
        #expect(unusable.mergingDefaults(into: []) == [])
    }

    @Test("The longest usable directory leaves room for OpenSSH's bind suffix")
    func longestUsableDirectory() {
        // 45 bytes + "/" + 40-hex name + 17-byte bind suffix = 103.
        let directory = "/Users/" + String(repeating: "a", count: 28) + "/.cmux/ssh"
        let options = SSHConnectionSharingOptions(userID: 501, controlSocketDirectoryPath: directory)

        #expect(directory.utf8.count == 45)
        #expect(options.defaultControlPath == directory + "/%C")
    }

    @Test("Only 40 lowercase hex names in the private directory are cmux-owned", arguments: [
        "/Users/alice/.cmux/ssh/0123456789ABCDEF0123456789abcdef01234567",
        "/Users/alice/.cmux/ssh/0123456789abcdef0123456789abcdef0123456",
        "/Users/alice/.cmux/ssh/0123456789abcdef0123456789abcdef012345678",
        "/Users/alice/.cmux/ssh/tmux-host-0123456789.sock",
        "/Users/alice/.cmux/ssh/../0123456789abcdef0123456789abcdef01234567",
        "/Users/alice/.cmux/sshx/0123456789abcdef0123456789abcdef01234567",
        "/Users/alice/.cmux/0123456789abcdef0123456789abcdef01234567",
    ])
    func onlyExactResolvedNamesAreOwned(path: String) {
        #expect(options.cmuxOwnedControlPath(in: ["ControlMaster=auto", "ControlPath=\(path)"]) == nil)
        #expect(options.resolvedControlMasterAuthenticationLockPath(controlPath: path) == nil)
    }

    @Test(
        "Stale-socket preflight passes the destination as one host operand",
        arguments: [
            "alice@example.test\n",
            "alice@example.test\r",
            "alice@example.test\r\n",
            "alice\n@example.test",
        ]
    )
    func preflightPassesDestinationAsOneHostOperand(destination: String) throws {
        let function = try #require(options.controlPathPreflightShellFunction(
            sshArguments: ["ssh", "-p", "2222"],
            destination: destination,
            options: options.mergingDefaults(into: [])
        ))

        #expect(function.contains("ssh -p 2222 -G -- '\(destination)' 2>/dev/null"))
        #expect(function.contains("-O check -- '\(destination)' >/dev/null"))
    }
}
