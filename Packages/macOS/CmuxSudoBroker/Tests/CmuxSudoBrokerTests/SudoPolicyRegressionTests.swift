@testable import CmuxSudoBroker
import Foundation
import Testing

@Suite("Sudo broker policies")
struct SudoPolicyRegressionTests {
    @Test("PAM parser requires an active sufficient pam_tid rule")
    func pamParser() {
        #expect(!SudoPAMConfiguration.containsEnabledEntry("#auth sufficient pam_tid.so\n"))
        #expect(SudoPAMConfiguration.containsEnabledEntry("auth   sufficient   pam_tid.so\n"))
        #expect(!SudoPAMConfiguration.containsEnabledEntry("auth required pam_tid.so\n"))
    }

    @Test("PAM reader accepts Touch ID from either sudo policy")
    func pamPolicyLocations() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let localURL = fixture.root.appendingPathComponent("sudo_local")
        let systemURL = fixture.root.appendingPathComponent("sudo")
        try Data("# auth sufficient pam_tid.so\n".utf8).write(to: localURL)
        try Data("auth sufficient pam_tid.so\n".utf8).write(to: systemURL)

        let configuration = SudoPAMConfiguration(fileURLs: [localURL, systemURL])

        #expect(configuration.touchIDIsEnabled())
    }

    @Test("CLI timeout distinguishes approved execution from pending approval")
    func phaseAwareCLITimeout() {
        #expect(SudoCLITimeoutDisposition.resolve(phase: nil) == .pendingApproval)
        #expect(SudoCLITimeoutDisposition.resolve(phase: .pendingApproval) == .pendingApproval)
        #expect(SudoCLITimeoutDisposition.resolve(phase: .approved) == .approvedExecution)
        #expect(SudoCLITimeoutDisposition.resolve(phase: .executing) == .approvedExecution)
    }

    @Test("Bundle scopes cannot escape the sudo spool root")
    func reservedBundleScopes() {
        let applicationSupport = URL(
            fileURLWithPath: "/tmp/cmux-sudo-policy-tests",
            isDirectory: true
        )
        for identifier in ["", ".", ".."] {
            let paths = SudoBrokerPaths(
                applicationSupportDirectory: applicationSupport,
                bundleIdentifier: identifier
            )
            #expect(paths.base.lastPathComponent == "com.cmuxterm.app")
            #expect(paths.base.deletingLastPathComponent().lastPathComponent == "sudo")
        }
    }

    @Test("Helper environment excludes unrelated inherited secrets")
    func helperEnvironmentAllowlist() {
        let environment = SudoProcessEnvironment(
            inherited: [
                "HOME": "/Users/test",
                "LC_MESSAGES": "ja_JP.UTF-8",
                "PATH": "/tmp/untrusted-bin",
                "SECRET_TOKEN": "do-not-forward",
            ]
        ).entries

        #expect(environment.contains("HOME=/Users/test"))
        #expect(environment.contains("LC_MESSAGES=ja_JP.UTF-8"))
        #expect(environment.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
        #expect(!environment.contains(where: { $0.hasPrefix("SECRET_TOKEN=") }))
    }

    @Test("Kevent timeout conversion clamps before integer conversion")
    func keventTimeoutClamping() {
        #expect(SudoKeventTimeout(seconds: -.infinity).milliseconds == 1)
        #expect(SudoKeventTimeout(seconds: 0.001).milliseconds == 1)
        #expect(SudoKeventTimeout(seconds: .infinity).milliseconds == Int.max)
        #expect(SudoKeventTimeout(seconds: .greatestFiniteMagnitude).milliseconds == Int.max)
    }

    @Test("Authentication detection ignores ordinary script output")
    func authenticationPromptOwnership() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let outputURL = fixture.paths.results.appendingPathComponent("auth-output.txt")
        let detector = SudoAuthenticationOutputDetector()

        try Data("Password: nested tool prompt\n".utf8).write(to: outputURL)
        #expect(!detector.indicatesPasswordPrompt(at: outputURL))

        try Data(SudoAuthenticationOutputDetector.passwordPrompt.utf8).write(to: outputURL)
        #expect(detector.indicatesPasswordPrompt(at: outputURL))
    }

    @Test("Orphan inventory rejects a PID generation that changes during argument capture")
    func orphanInventoryRejectsPIDReuseRace() throws {
        let fixture = try SudoTestFixture()
        defer { fixture.remove() }
        let approvedScriptURL = fixture.paths.approved
            .appendingPathComponent("pid-reuse.sh", isDirectory: false)
        let processIdentifier: Int32 = 4_242
        let initialIdentity = SudoProcessIdentity(
            processIdentifier: processIdentifier,
            startSeconds: 100,
            startMicroseconds: 10
        )
        let reusedIdentity = SudoProcessIdentity(
            processIdentifier: processIdentifier,
            startSeconds: 101,
            startMicroseconds: 20
        )
        let inspector = SequencedSudoProcessInspector(
            processIdentifier: processIdentifier,
            identities: [initialIdentity, reusedIdentity],
            arguments: [
                "/usr/bin/script", "-q", "/dev/null", "/usr/bin/sudo", "-k",
                "-p", SudoAuthenticationOutputDetector.passwordPrompt,
                "/bin/bash", approvedScriptURL.path,
            ]
        )

        let inventory = SudoOrphanProcessInventory(inspector: inspector)
            .identitiesByScriptPath(approvedScriptURLs: [approvedScriptURL])

        #expect(inventory[approvedScriptURL.standardizedFileURL.path]?.isEmpty == true)
    }
}
