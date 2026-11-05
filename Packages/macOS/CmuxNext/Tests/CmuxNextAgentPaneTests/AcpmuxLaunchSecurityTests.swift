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

    /// The nightly hang reports of 2026-11-05: `resolve`'s signature check read the whole acpmux
    /// file on the main thread (1.7-2.1 s each, `GitHubAppLease` and `QuitAgents` callers). The
    /// check `resolve` makes now reads the signed code directory only, so a copy whose code pages
    /// changed after signing still passes it, and the launch gate (`.strict`) still refuses it.
    @Test func resolvesCheckReadsTheCodeDirectoryAndTheLaunchGateReadsEveryPage() throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("acpmux-sig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: copy)
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess)
        let anchor = try #require(requirement)
        #expect(AcpmuxServerPeer.signatureValid(copy, requirement: anchor, validation: .strict))
        // One byte of the first slice's code (its second 16 KiB page), past the headers and well
        // before the signature at the slice's end.
        var bytes = try Data(contentsOf: copy)
        let fat = bytes.prefix(4).elementsEqual([0xCA, 0xFE, 0xBA, 0xBE])
        let slice = fat ? bytes[16..<20].reduce(0) { $0 << 8 | Int($1) } : 0
        bytes[slice + 0x4100] ^= 0xFF
        try bytes.write(to: copy)

        #expect(!AcpmuxServerPeer.signatureValid(copy, requirement: anchor, validation: .strict))
        #expect(AcpmuxServerPeer.signatureValid(copy, requirement: anchor, validation: .codeDirectory))
        #expect(AcpmuxEnvironment.resolveValidation == .codeDirectory)
    }
}
