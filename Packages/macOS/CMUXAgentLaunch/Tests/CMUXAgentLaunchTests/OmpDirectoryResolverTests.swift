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

    @Test("Launch selectors follow OMP argv boundaries and last-value precedence")
    func launchSelectorsMatchOmpArgumentParsing() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolver = OmpDirectoryResolver()
        let defaultSessions = fixture.home.appendingPathComponent(".omp/agent/sessions", isDirectory: true)

        let repeated = try resolver.resolve(
            arguments: [
                "omp", "launch", "hello",
                "--profile", "personal",
                "--session-dir", "first",
                "--profile=work",
                "--session-dir=second",
            ],
            environment: [:],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )
        #expect(repeated.profile == "work")
        #expect(repeated.sessionsDirectory == fixture.currentDirectory.appendingPathComponent("second").path)

        let consumedProfile = try resolver.resolve(
            arguments: [
                "omp",
                "--system-prompt", "--profile",
                "work",
                "--session-dir", "actual",
            ],
            environment: [:],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )
        #expect(consumedProfile.profile == nil)
        #expect(consumedProfile.sessionsDirectory == fixture.currentDirectory.appendingPathComponent("actual").path)

        let afterSeparator = try resolver.resolve(
            arguments: ["omp", "--", "--profile", "work", "--session-dir", "ignored"],
            environment: [:],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )
        #expect(afterSeparator.profile == nil)
        #expect(afterSeparator.sessionsDirectory == defaultSessions.path)

        let subcommand = try resolver.resolve(
            arguments: ["omp", "grep", "--profile", "work", "--session-dir", "ignored"],
            environment: [:],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )
        #expect(subcommand.profile == nil)
        #expect(subcommand.sessionsDirectory == defaultSessions.path)

        let shadowedPlan = try resolver.resolve(
            arguments: ["omp", "--plan", "--profile", "work"],
            environment: [:],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )
        #expect(shadowedPlan.profile == "work")
    }

    @Test("Session directory accepts raw flag-looking values and empty last values")
    func sessionDirectoryMatchesOmpStringFlagSemantics() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolver = OmpDirectoryResolver()

        let flagLooking = try resolver.resolve(
            arguments: [
                "omp",
                "--session-dir", "first",
                "--session-dir", "--literal-directory",
            ],
            environment: [:],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )
        #expect(
            flagLooking.sessionsDirectory
                == fixture.currentDirectory.appendingPathComponent("--literal-directory").path
        )

        let emptyLastValue = try resolver.resolve(
            arguments: ["omp", "--session-dir", "first", "--session-dir="],
            environment: [:],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )
        #expect(
            emptyLastValue.sessionsDirectory
                == fixture.home.appendingPathComponent(".omp/agent/sessions", isDirectory: true).path
        )
    }

    @Test("Default agent path remains eligible for XDG sessions")
    func defaultAgentOverrideKeepsXdgPrecedence() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let defaultAgent = fixture.home.appendingPathComponent(".omp/agent", isDirectory: true)
        let xdgData = fixture.root.appendingPathComponent("xdg", isDirectory: true)
        let xdgOmp = xdgData.appendingPathComponent("omp", isDirectory: true)
        try FileManager.default.createDirectory(at: xdgOmp, withIntermediateDirectories: true)

        let resolution = try OmpDirectoryResolver().resolve(
            arguments: ["omp"],
            environment: [
                "PI_CODING_AGENT_DIR": defaultAgent.path,
                "XDG_DATA_HOME": xdgData.path,
            ],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )

        #expect(resolution.agentDirectory == defaultAgent.path)
        #expect(resolution.sessionsDirectory == xdgOmp.appendingPathComponent("sessions").path)
    }

    @Test("Inherited profile suppression uses OMP raw path equality")
    func inheritedProfileAgentDirectoryComparisonIsRaw() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profileAgent = fixture.home.appendingPathComponent(
            ".omp/profiles/work/agent",
            isDirectory: true
        )

        let resolution = try OmpDirectoryResolver().resolve(
            arguments: ["omp", "--profile", "default"],
            environment: [
                "PI_PROFILE": "work",
                "PI_CODING_AGENT_DIR": ".omp/profiles/work/agent",
            ],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.home.path
        )

        #expect(resolution.agentDirectory == profileAgent.path)
        #expect(resolution.sessionsDirectory == profileAgent.appendingPathComponent("sessions").path)
    }

    @Test("Directory overrides preserve raw whitespace")
    func directoryOverridesDoNotTrimPaths() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolution = try OmpDirectoryResolver().resolve(
            arguments: ["omp"],
            environment: [
                "PI_CONFIG_DIR": " omp config ",
                "PI_CODING_AGENT_DIR": " agents/custom ",
            ],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )

        #expect(
            resolution.configDirectory
                == fixture.home.appendingPathComponent(" omp config ", isDirectory: true).path
        )
        #expect(
            resolution.agentDirectory
                == fixture.currentDirectory.appendingPathComponent(" agents/custom ", isDirectory: true).path
        )
    }

    @Test("Relative session directory follows OMP startup cwd")
    func relativeSessionDirectoryUsesEffectiveStartupDirectory() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let explicitCwd = fixture.currentDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: explicitCwd, withIntermediateDirectories: true)

        let explicit = try OmpDirectoryResolver().resolve(
            arguments: ["omp", "--cwd", "nested", "--session-dir", "sessions"],
            environment: [:],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path
        )
        #expect(explicit.currentDirectory == explicitCwd.path)
        #expect(explicit.sessionsDirectory == explicitCwd.appendingPathComponent("sessions").path)

        let homeTemporary = fixture.home.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: homeTemporary, withIntermediateDirectories: true)
        let autoMoved = try OmpDirectoryResolver().resolve(
            arguments: ["omp", "--session-dir", "sessions"],
            environment: [:],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.home.path
        )
        #expect(autoMoved.currentDirectory == homeTemporary.path)
        #expect(autoMoved.sessionsDirectory == homeTemporary.appendingPathComponent("sessions").path)

        let allowedHome = try OmpDirectoryResolver().resolve(
            arguments: ["omp", "--allow-home", "--session-dir", "sessions"],
            environment: [:],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.home.path
        )
        #expect(allowedHome.currentDirectory == fixture.home.path)
        #expect(allowedHome.sessionsDirectory == fixture.home.appendingPathComponent("sessions").path)
    }

    @Test("Historical roots retain distinct config and XDG session stores")
    func sessionRootsIncludeCurrentAndLegacyStores() throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configDefault = fixture.home.appendingPathComponent(
            ".omp/agent/sessions",
            isDirectory: true
        )
        let configProfile = fixture.home.appendingPathComponent(
            ".omp/profiles/work/agent/sessions",
            isDirectory: true
        )
        let xdgData = fixture.root.appendingPathComponent("xdg", isDirectory: true)
        let xdgDefault = xdgData.appendingPathComponent("omp/sessions", isDirectory: true)
        let xdgProfile = xdgData.appendingPathComponent(
            "omp/profiles/work/sessions",
            isDirectory: true
        )
        for directory in [configDefault, configProfile, xdgDefault, xdgProfile] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let roots = OmpDirectoryResolver().sessionRoots(
            environment: ["XDG_DATA_HOME": xdgData.path],
            homeDirectory: fixture.home.path,
            currentDirectory: fixture.currentDirectory.path,
            fileManager: .default
        )

        #expect(roots.map(\.path) == [
            xdgDefault.path,
            configDefault.path,
            xdgProfile.path,
            configProfile.path,
        ])
        #expect(roots.map(\.profile) == [nil, nil, "work", "work"])
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
