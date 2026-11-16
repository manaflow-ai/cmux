import Foundation
import Security
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxLaunchSecurityTests {
    private static func environment() throws -> AcpmuxEnvironment {
        try #require(AcpmuxEnvironment.resolve(
            build: nil,
            bundledBinDirectory: URL(fileURLWithPath: "/App/bin", isDirectory: true),
            environment: [:],
            userHome: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            uid: 501,
            isExecutable: { _ in true },
            executableOverride: nil
        ))
    }

    @Test func signedLaunchWithholdsTheSpawnPersonKey() throws {
        var environment = try Self.environment()
        environment.passesPersonKeyAtSpawn = false

        let arguments = AcpmuxDaemonLauncher.arguments(for: environment)

        #expect(!arguments.contains("--person-key-fd"))
        #expect(!arguments.contains(String(AcpmuxDaemonLauncher.personKeyDescriptor)))
    }

    @Test func spawnEnvironmentWithholdsLegacyComputerUseSecrets() throws {
        var environment = try Self.environment()
        environment.passesPersonKeyAtSpawn = false
        environment.computerUse = [
            "CMUX_NEXT_CUA_SOCKET": "/private/helper.sock",
            "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN": "fixture-secret",
            "CMUX_NEXT_CUA_V2_DIR": "/private/v2",
        ]

        let variables = AcpmuxDaemonLauncher.spawnEnvironment(
            environment,
            inherited: [
                "CMUX_NEXT_CUA_SOCKET": "/inherited.sock",
                "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN": "inherited-secret",
                "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN": "host-secret",
                "PATH": "/usr/bin",
            ]
        )

        #expect(variables["CMUX_NEXT_CUA_SOCKET"] == nil)
        #expect(variables["CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"] == nil)
        #expect(variables["CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN"] == nil)
        #expect(variables["CMUX_NEXT_CUA_V2_DIR"] == "/private/v2")
        #expect(variables["PATH"] == "/usr/bin")
    }

    @Test func unsignedDevelopmentLaunchKeepsLegacyComputerUseAgentCredentials() throws {
        var environment = try Self.environment()
        environment.passesPersonKeyAtSpawn = true
        environment.computerUse = [
            "CMUX_NEXT_CUA_SOCKET": "/private/helper.sock",
            "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN": "fixture-secret",
            "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN": "host-secret",
        ]

        let variables = AcpmuxDaemonLauncher.spawnEnvironment(environment, inherited: [:])

        #expect(variables["CMUX_NEXT_CUA_SOCKET"] == "/private/helper.sock")
        #expect(variables["CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"] == "fixture-secret")
        #expect(variables["CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN"] == nil)
    }

    @Test func signedComputerUseEnrollmentCarriesOnlyTheAgentCredential() throws {
        var environment = try Self.environment()
        environment.passesPersonKeyAtSpawn = false
        environment.computerUse = [
            "CMUX_NEXT_CUA_SOCKET": "/private/helper.sock",
            "CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN": "fixture-secret",
            "CMUX_NEXT_CUA_SOCKET_HOST_AUTH_TOKEN": "host-secret",
            "CMUX_NEXT_CUA_V2_DIR": "/private/v2",
        ]

        let parameters = AcpmuxComputerUse.enrollmentParameters(environment)

        #expect(parameters["socket"] as? String == "/private/helper.sock")
        #expect(parameters["agentToken"] as? String == "fixture-secret")
        #expect(parameters.count == 2)
    }

    @Test func signedLaunchDoesNotInheritUnrelatedApplicationSecrets() throws {
        var environment = try Self.environment()
        environment.passesPersonKeyAtSpawn = false

        let variables = AcpmuxDaemonLauncher.spawnEnvironment(
            environment,
            inherited: [
                "HOME": "/Users/test",
                "LANG": "en_US.UTF-8",
                "PATH": "/usr/bin:/bin",
                "OPENAI_API_KEY": "fixture-secret",
                "UNRELATED_SESSION_TOKEN": "fixture-secret",
            ]
        )

        #expect(variables["HOME"] == "/Users/test")
        #expect(variables["LANG"] == "en_US.UTF-8")
        #expect(variables["PATH"] == "/usr/bin:/bin")
        #expect(variables["OPENAI_API_KEY"] == nil)
        #expect(variables["UNRELATED_SESSION_TOKEN"] == nil)
    }

    @Test func unsignedDevelopmentLaunchKeepsItsApplicationEnvironment() throws {
        var environment = try Self.environment()
        environment.passesPersonKeyAtSpawn = true

        let variables = AcpmuxDaemonLauncher.spawnEnvironment(
            environment,
            inherited: ["DEVELOPMENT_TEST_VALUE": "present"]
        )

        #expect(variables["DEVELOPMENT_TEST_VALUE"] == "present")
    }

    @Test func signedResolutionRejectsAnExecutableOutsideTheAppsTeam() {
        var checkedTeam: String?
        let environment = AcpmuxEnvironment.resolve(
            build: nil,
            bundledBinDirectory: URL(fileURLWithPath: "/App/bin", isDirectory: true),
            environment: [:],
            userHome: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            uid: 501,
            isExecutable: { _ in true },
            executableOverride: nil,
            teamIdentifier: "TEAM123",
            isTrustedExecutable: { _, team in checkedTeam = team; return false }
        )

        #expect(checkedTeam == "TEAM123")
        #expect(environment == nil)
    }

    @Test func signedResolutionDefersItsPersonKeyUntilPeerEnrollment() throws {
        let environment = try #require(AcpmuxEnvironment.resolve(
            build: nil,
            bundledBinDirectory: URL(fileURLWithPath: "/App/bin", isDirectory: true),
            environment: [:],
            userHome: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            uid: 501,
            isExecutable: { _ in true },
            executableOverride: nil,
            teamIdentifier: "TEAM123",
            isTrustedExecutable: { _, _ in true }
        ))

        #expect(!environment.passesPersonKeyAtSpawn)
    }

    @Test func staticLaunchCheckRejectsAnotherTeamsExecutable() {
        let systemBinary = URL(fileURLWithPath: "/bin/ls")
        #expect(!AcpmuxServerPeer.executableSignedByAppTeam(systemBinary, team: "NOTCMUXTEAM"))
        #expect(!AcpmuxServerPeer.executableSignedByAppTeam(systemBinary, team: "invalid team"))
    }

    /// Launch: the first strict check of a process hashed every page of the bundled `cmux` (148 MB) on
    /// the main thread, 2.5 s on a cold disk cache. A binary the kernel kills at a bad page (hardened
    /// runtime, as every Team-signed nightly binary) is checked without its pages; one without that
    /// flag still has every page hashed.
    @Test func strictTeamCheckHashesPagesOnlyWhenTheKernelWouldNot() throws {
        let plain = URL(fileURLWithPath: "/bin/ls")
        let hardened = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: hardened) }
        try FileManager.default.copyItem(at: plain, to: hardened)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--options", "runtime", hardened.path]
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)

        func flags(_ url: URL) throws -> UInt32 {
            var code: SecStaticCode?
            try #require(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess)
            return AcpmuxServerPeer.strictFlags(for: try #require(code)).rawValue
        }
        let strict = kSecCSCheckAllArchitectures | kSecCSStrictValidate
        #expect(try flags(plain) == strict)
        #expect(try flags(hardened) == strict | kSecCSDoNotValidateExecutable)
    }

    /// A script signed with `--options runtime` carries the runtime flag in a signature kept in
    /// extended attributes, but the kernel never checks a script's contents. It is hashed in full,
    /// so a script changed after signing fails the strict check.
    @Test func strictTeamCheckHashesASignedScriptAndRejectsItOnceChanged() throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-sh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: script) }
        try Data("#!/bin/sh\necho signed\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--options", "runtime", script.path]
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)

        func check() throws -> (flags: UInt32, status: OSStatus) {
            var code: SecStaticCode?
            try #require(SecStaticCodeCreateWithPath(script as CFURL, [], &code) == errSecSuccess)
            let flags = AcpmuxServerPeer.strictFlags(for: try #require(code))
            return (flags.rawValue, SecStaticCodeCheckValidity(try #require(code), flags, nil))
        }
        let strict = kSecCSCheckAllArchitectures | kSecCSStrictValidate
        let signed = try check()
        #expect(signed.flags == strict)
        #expect(signed.status == errSecSuccess)

        // Changed after signing; its extended-attribute signature stays.
        let handle = try FileHandle(forWritingTo: script)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("echo changed\n".utf8))
        try handle.close()
        #expect(try check().status != errSecSuccess)
    }

    /// The nightly hang reports of 2026-11-05: `resolve`'s strict signature check read the whole
    /// acpmux file on the main thread every time it was asked (1.7-2.1 s each, `QuitAgents` and
    /// `GitHubAppLease` callers). The verdict is kept for the file as it is on disk, so asking again
    /// reads nothing; any write to the file (its pages changed in place, or another file renamed
    /// over it) changes its identity and the file is read again.
    @Test func strictTeamCheckReadsAFileOnceUntilItChanges() throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-sig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: copy)
        // A clock well past the file's times; the settle rule is checked below.
        let verdicts = AcpmuxServerPeer.StrictVerdicts(now: { Int64(Date().timeIntervalSince1970) + 60 })
        var reads = 0
        let check = { verdicts.verdict(path: copy.path, team: "TEAM") { reads += 1; return true } }

        #expect(check())
        #expect(check())
        #expect(reads == 1)

        // One byte changed in place, as a page patched after signing would be.
        let handle = try FileHandle(forUpdating: copy)
        try handle.seek(toOffset: 0x4100)
        let byte = try #require(try handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: 0x4100)
        try handle.write(contentsOf: Data([byte ^ 0xFF]))
        try handle.close()
        #expect(check())
        #expect(reads == 2)

        // Another file renamed over it.
        let other = copy.appendingPathExtension("new")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: other)
        #expect(rename(other.path, copy.path) == 0)
        #expect(check())
        #expect(reads == 3)

        // Another team is its own question, and a refusal is never kept.
        #expect(!verdicts.verdict(path: copy.path, team: "OTHER") { reads += 1; return false })
        #expect(!verdicts.verdict(path: copy.path, team: "OTHER") { reads += 1; return false })
        #expect(reads == 5)
        #expect(check())
        #expect(reads == 5)

        // A file that cannot be read is never kept.
        let missing = copy.appendingPathExtension("missing").path
        #expect(!verdicts.verdict(path: missing, team: "TEAM") { reads += 1; return false })
        #expect(!verdicts.verdict(path: missing, team: "TEAM") { reads += 1; return false })
        #expect(reads == 7)

        // A file changed within the settle time is never kept: a coarse timestamp could hide a
        // second write in the same second.
        let fresh = AcpmuxServerPeer.StrictVerdicts(now: { Int64(Date().timeIntervalSince1970) })
        #expect(fresh.verdict(path: copy.path, team: "TEAM") { reads += 1; return true })
        #expect(fresh.verdict(path: copy.path, team: "TEAM") { reads += 1; return true })
        #expect(reads == 9)
    }
}
