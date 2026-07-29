import CMUXAgentLaunch
import Foundation
import Testing

@Suite("OmpDirectoryResolver")
struct OmpDirectoryResolverTests {
    @Test("CLI profile overrides OMP_PROFILE and PI_PROFILE")
    func cliProfileOverridesEnvironmentProfiles() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for arguments in [["omp", "--profile", "work"], ["omp", "--profile=work"]] {
            let resolution = try OmpDirectoryResolver().resolve(
                arguments: arguments,
                environment: [
                    "OMP_PROFILE": "personal",
                    "PI_PROFILE": "legacy",
                ],
                homeDirectory: fixture.home.path,
                currentDirectory: fixture.currentDirectory.path
            )
            let profileDirectory = fixture.home
                .appendingPathComponent(".omp", isDirectory: true)
                .appendingPathComponent("profiles/work", isDirectory: true)

            #expect(resolution.profile == "work")
            #expect(resolution.configDirectory == profileDirectory.path)
            #expect(resolution.agentDirectory == profileDirectory.appendingPathComponent("agent", isDirectory: true).path)
            #expect(resolution.sessionsDirectory == profileDirectory.appendingPathComponent("agent/sessions", isDirectory: true).path)
        }
    }

    @Test("OMP_PROFILE presence suppresses PI_PROFILE for default-profile values")
    func ompProfilePresenceSuppressesPiProfile() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for ompProfile in ["", "   ", "default"] {
            let resolution = try OmpDirectoryResolver().resolve(
                arguments: ["omp"],
                environment: [
                    "OMP_PROFILE": ompProfile,
                    "PI_PROFILE": "work",
                ],
                homeDirectory: fixture.home.path,
                currentDirectory: fixture.currentDirectory.path
            )

            #expect(resolution.profile == nil)
            #expect(resolution.configDirectory == fixture.home.appendingPathComponent(".omp", isDirectory: true).path)
        }
    }

    @Test("Explicit default profile ignores an inherited named-profile agent directory")
    func explicitDefaultProfileIgnoresInheritedNamedAgentDirectory() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let defaultConfigDirectory = fixture.home.appendingPathComponent(".omp", isDirectory: true)
        let inheritedNamedAgentDirectory = defaultConfigDirectory
            .appendingPathComponent("profiles/work/agent", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inheritedNamedAgentDirectory,
            withIntermediateDirectories: true
        )

        let resolution = try OmpDirectoryResolver().resolve(
            arguments: ["omp", "--profile", "default"],
            environment: [
                "OMP_PROFILE": "work",
                "PI_PROFILE": "legacy",
                "PI_CODING_AGENT_DIR": inheritedNamedAgentDirectory.path,
            ],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )

        let defaultAgentDirectory = defaultConfigDirectory.appendingPathComponent("agent", isDirectory: true)
        #expect(resolution.profile == nil)
        #expect(resolution.configDirectory == defaultConfigDirectory.path)
        #expect(resolution.agentDirectory == defaultAgentDirectory.path)
        #expect(resolution.sessionsDirectory == defaultAgentDirectory.appendingPathComponent("sessions").path)
    }

    @Test("PI_PROFILE is used only when OMP_PROFILE is absent")
    func piProfileIsFallbackEnvironmentProfile() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolution = try OmpDirectoryResolver().resolve(
            arguments: ["omp"],
            environment: ["PI_PROFILE": "work-2.0_a"],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )

        let profileDirectory = fixture.home
            .appendingPathComponent(".omp/profiles/work-2.0_a", isDirectory: true)
        #expect(resolution.profile == "work-2.0_a")
        #expect(resolution.configDirectory == profileDirectory.path)
        #expect(resolution.agentDirectory == profileDirectory.appendingPathComponent("agent", isDirectory: true).path)
        #expect(resolution.sessionsDirectory == profileDirectory.appendingPathComponent("agent/sessions", isDirectory: true).path)
    }

    @Test("Named profiles ignore PI_CODING_AGENT_DIR")
    func namedProfileIgnoresCustomAgentDirectory() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let customAgentDirectory = fixture.root.appendingPathComponent("ambient-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: customAgentDirectory, withIntermediateDirectories: true)

        let resolution = try OmpDirectoryResolver().resolve(
            arguments: ["omp", "--profile", "work"],
            environment: ["PI_CODING_AGENT_DIR": customAgentDirectory.path],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )

        let profileAgentDirectory = fixture.home
            .appendingPathComponent(".omp/profiles/work/agent", isDirectory: true)
        #expect(resolution.profile == "work")
        #expect(resolution.agentDirectory == profileAgentDirectory.path)
        #expect(resolution.sessionsDirectory == profileAgentDirectory.appendingPathComponent("sessions", isDirectory: true).path)
    }

    @Test("Default profile resolves a relative custom agent directory from cwd")
    func defaultProfileUsesCustomAgentDirectory() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let customAgentDirectory = fixture.currentDirectory.appendingPathComponent("agents/custom", isDirectory: true)
        let xdgOmpDirectory = fixture.root.appendingPathComponent("xdg/omp", isDirectory: true)
        try FileManager.default.createDirectory(at: customAgentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xdgOmpDirectory, withIntermediateDirectories: true)

        let resolution = try OmpDirectoryResolver().resolve(
            arguments: ["omp"],
            environment: [
                "PI_CODING_AGENT_DIR": "agents/custom",
                "PI_CODING_AGENT_SESSION_DIR": fixture.root.appendingPathComponent("ignored-sessions").path,
                "XDG_DATA_HOME": fixture.root.appendingPathComponent("xdg", isDirectory: true).path,
            ],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )

        #expect(resolution.profile == nil)
        #expect(resolution.configDirectory == fixture.home.appendingPathComponent(".omp", isDirectory: true).path)
        #expect(resolution.agentDirectory == customAgentDirectory.path)
        #expect(resolution.sessionsDirectory == customAgentDirectory.appendingPathComponent("sessions", isDirectory: true).path)
    }

    @Test("PI_CONFIG_DIR is joined to HOME even when it starts with a slash")
    func piConfigDirectoryUsesExactHomeJoinedSemantics() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolution = try OmpDirectoryResolver().resolve(
            arguments: ["omp"],
            environment: ["PI_CONFIG_DIR": "/absolute/custom-omp"],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )

        let configDirectory = fixture.home.appendingPathComponent("absolute/custom-omp", isDirectory: true)
        #expect(resolution.configDirectory == configDirectory.path)
        #expect(resolution.agentDirectory == configDirectory.appendingPathComponent("agent", isDirectory: true).path)
        #expect(resolution.sessionsDirectory == configDirectory.appendingPathComponent("agent/sessions", isDirectory: true).path)
    }

    @Test("Default profile uses XDG sessions only when the OMP data root exists")
    func defaultProfileRequiresExistingXdgDataRoot() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let xdgDataHome = fixture.root.appendingPathComponent("xdg-data", isDirectory: true)
        let xdgOmpRoot = xdgDataHome.appendingPathComponent("omp", isDirectory: true)
        let configSessions = fixture.home.appendingPathComponent(".omp/agent/sessions", isDirectory: true)

        let beforeCreation = try OmpDirectoryResolver().resolve(
            arguments: ["omp"],
            environment: ["XDG_DATA_HOME": xdgDataHome.path],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )
        #expect(beforeCreation.sessionsDirectory == configSessions.path)

        try FileManager.default.createDirectory(at: xdgOmpRoot, withIntermediateDirectories: true)
        let afterCreation = try OmpDirectoryResolver().resolve(
            arguments: ["omp"],
            environment: ["XDG_DATA_HOME": xdgDataHome.path],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )
        #expect(afterCreation.sessionsDirectory == xdgOmpRoot.appendingPathComponent("sessions", isDirectory: true).path)
    }

    @Test("Named profiles require their own XDG profile data root")
    func namedProfileRequiresExistingXdgProfileDataRoot() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let xdgDataHome = fixture.root.appendingPathComponent("xdg-data", isDirectory: true)
        let xdgOmpRoot = xdgDataHome.appendingPathComponent("omp", isDirectory: true)
        let xdgProfileRoot = xdgOmpRoot.appendingPathComponent("profiles/work", isDirectory: true)
        let configSessions = fixture.home.appendingPathComponent(".omp/profiles/work/agent/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: xdgOmpRoot, withIntermediateDirectories: true)

        let withoutProfileRoot = try OmpDirectoryResolver().resolve(
            arguments: ["omp", "--profile", "work"],
            environment: ["XDG_DATA_HOME": xdgDataHome.path],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )
        #expect(withoutProfileRoot.sessionsDirectory == configSessions.path)

        try FileManager.default.createDirectory(at: xdgProfileRoot, withIntermediateDirectories: true)
        let withProfileRoot = try OmpDirectoryResolver().resolve(
            arguments: ["omp", "--profile", "work"],
            environment: ["XDG_DATA_HOME": xdgDataHome.path],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )
        #expect(withProfileRoot.sessionsDirectory == xdgProfileRoot.appendingPathComponent("sessions", isDirectory: true).path)
    }

    @Test("Explicit session directory wins and is resolved directly from cwd")
    func explicitSessionDirectoryHasHighestPathPrecedence() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let explicitSessions = fixture.currentDirectory.appendingPathComponent("explicit-sessions", isDirectory: true)
        let xdgProfileRoot = fixture.root.appendingPathComponent("xdg/omp/profiles/work", isDirectory: true)
        try FileManager.default.createDirectory(at: explicitSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xdgProfileRoot, withIntermediateDirectories: true)

        let resolution = try OmpDirectoryResolver().resolve(
            arguments: [
                "omp",
                "--profile",
                "work",
                "--session-dir",
                "explicit-sessions",
            ],
            environment: [
                "OMP_PROFILE": "personal",
                "PI_CODING_AGENT_DIR": fixture.root.appendingPathComponent("ambient-agent").path,
                "XDG_DATA_HOME": fixture.root.appendingPathComponent("xdg").path,
            ],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )

        #expect(resolution.profile == "work")
        #expect(resolution.sessionsDirectory == explicitSessions.path)
    }

    @Test("Invalid CLI and environment profile names are rejected")
    func rejectsInvalidProfileNames() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invalidNames = [
            "WORK",
            "Work",
            ".",
            "..",
            "../work",
            "work/team",
            "work.",
            String(repeating: "a", count: 65),
            "con",
            "prn",
            "com0",
            "lpt9",
            "CON.txt",
        ]

        for name in invalidNames {
            var environmentError: (any Error)?
            do {
                _ = try OmpDirectoryResolver().resolve(
                    arguments: ["omp"],
                    environment: ["OMP_PROFILE": name],
                    homeDirectory: fixture.home.path,
                    currentDirectory: fixture.currentDirectory.path
                )
            } catch {
                environmentError = error
            }
            #expect(
                environmentError != nil,
                Comment(rawValue: "Expected invalid OMP_PROFILE to throw: \(name)")
            )

            var cliError: (any Error)?
            do {
                _ = try OmpDirectoryResolver().resolve(
                    arguments: ["omp", "--profile", name],
                    environment: [:],
                    homeDirectory: fixture.home.path,
                    currentDirectory: fixture.currentDirectory.path
                )
            } catch {
                cliError = error
            }
            #expect(
                cliError != nil,
                Comment(rawValue: "Expected invalid --profile to throw: \(name)")
            )
        }
    }

    @Test("Missing or empty explicit profile values are rejected")
    func rejectsMalformedExplicitProfiles() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for arguments in [
            ["omp", "--profile"],
            ["omp", "--profile="],
            ["omp", "--profile", "   "],
            ["omp", "--profile", "--model", "anthropic/claude-sonnet-4-6"],
        ] {
            var thrownError: (any Error)?
            do {
                _ = try OmpDirectoryResolver().resolve(
                    arguments: arguments,
                    environment: [:],
                    homeDirectory: fixture.home.path,
                    currentDirectory: fixture.currentDirectory.path
                )
            } catch {
                thrownError = error
            }
            #expect(thrownError != nil, Comment(rawValue: "Expected malformed arguments to throw: \(arguments)"))
        }
    }

    private static func makeFixture() throws -> (root: URL, home: URL, currentDirectory: URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("cmux-omp-directory-resolver-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let currentDirectory = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        return (root, home, currentDirectory)
    }
}
