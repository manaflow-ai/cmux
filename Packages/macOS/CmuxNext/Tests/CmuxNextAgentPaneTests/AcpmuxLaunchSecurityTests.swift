import Foundation
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

    /// cmuxterm-hq#6338: the check read the whole executable on every resolve (2.86 s on the main
    /// thread at launch). An unchanged file is read once; any change to it is checked again.
    @Test func theTeamCheckReadsAnUnchangedExecutableOnce() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acpmux-team-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("acpmux")
        try Data("signed".utf8).write(to: file)
        var reads = 0
        var verdict = true
        let check: (URL, String) -> Bool = { _, _ in reads += 1; return verdict }

        // A file written within the last few seconds keeps no verdict: on a volume with coarse
        // timestamps a same-length overwrite in the same tick would leave its identity unchanged.
        #expect(AcpmuxServerPeer.executableSignedByAppTeam(file, team: "TEAM123", validate: check))
        #expect(AcpmuxServerPeer.executableSignedByAppTeam(file, team: "TEAM123", validate: check))
        #expect(reads == 2)
        try Data("SIGNED".utf8).write(to: file) // the same length, written in place
        verdict = false
        #expect(!AcpmuxServerPeer.executableSignedByAppTeam(file, team: "TEAM123", validate: check))
        #expect(reads == 3)
        verdict = true
        reads = 0

        // Seen from a clock well past the last write, the file has settled.
        let later: () -> Date = { Date().addingTimeInterval(60) }
        func signed(_ url: URL, _ team: String) -> Bool {
            AcpmuxServerPeer.executableSignedByAppTeam(url, team: team, validate: check, now: later)
        }

        #expect(signed(file, "TEAM123"))
        #expect(signed(file, "TEAM123"))
        #expect(reads == 1)

        // Another team is its own check.
        #expect(signed(file, "OTHER"))
        #expect(reads == 2)

        // A write in place (same inode) is checked again, and its refusal holds.
        verdict = false
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("+payload".utf8))
        try handle.close()
        #expect(!signed(file, "TEAM123"))
        #expect(reads == 3)
        verdict = true
        #expect(!signed(file, "TEAM123"))
        #expect(reads == 3)

        // A replacement (a new inode at the path) is checked again.
        try Data("other".utf8).write(to: file, options: .atomic)
        #expect(signed(file, "TEAM123"))
        #expect(reads == 4)

        // A file that cannot be read keeps no verdict and is checked each time.
        let missing = directory.appendingPathComponent("missing")
        verdict = false
        #expect(!signed(missing, "TEAM123"))
        #expect(!signed(missing, "TEAM123"))
        #expect(reads == 6)
    }

    @Test func staticLaunchCheckRejectsAnotherTeamsExecutable() {
        let systemBinary = URL(fileURLWithPath: "/bin/ls")
        #expect(!AcpmuxServerPeer.executableSignedByAppTeam(systemBinary, team: "NOTCMUXTEAM"))
        #expect(!AcpmuxServerPeer.executableSignedByAppTeam(systemBinary, team: "invalid team"))
    }
}
