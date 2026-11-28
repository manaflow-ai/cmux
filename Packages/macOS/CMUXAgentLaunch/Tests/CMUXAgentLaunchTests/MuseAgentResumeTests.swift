import CMUXAgentLaunch
import Testing

@Suite("Muse Code agent resume")
struct MuseAgentResumeTests {
    private let sessionId = "01a131ca-9d50-73d2-964b-e18762313355"

    @Test("Resumes through Muse's resume subcommand")
    func buildsResumeSubcommandArgv() {
        #expect(
            AgentResumeArgv().registeredBuiltInKind(
                kind: .muse,
                sessionId: sessionId,
                executablePath: nil,
                arguments: ["muse"]
            ) == ["muse", "resume", sessionId]
        )
        #expect(RegisteredAgentResumeKind.muse.commandTemplate == "{{executable}} resume {{sessionId}}")
    }

    @Test("Resumes through the launcher when the versioned binary was captured")
    func replacesVersionedBinaryWithLauncher() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "muse",
                sessionId: sessionId,
                executablePath: "/Users/example/.local/bin/muse-bin-1.4.6-R6000.1",
                arguments: ["/Users/example/.local/bin/muse-bin-1.4.6-R6000.1", "--model", "muse-spark"]
            ) == ["/Users/example/.local/bin/muse", "resume", sessionId, "--model", "muse-spark"]
        )
        #expect(MuseExecutableName("muse-bin-1.4.6-R6000.1").resumeExecutable == "muse")
        #expect(MuseExecutableName("/opt/muse/bin/muse").resumeExecutable == "/opt/muse/bin/muse")
        #expect(MuseExecutableName("muse-bin-1.0.3-R").isVersionedBinary)
        #expect(!MuseExecutableName("muse-bin-").isVersionedBinary)
        #expect(!MuseExecutableName("muse").isVersionedBinary)
    }

    /// cmux#44791: the process scan asks this about every bare process name, and
    /// `URL(fileURLWithPath:)` paid a `getcwd` and an `lstat` to resolve each one
    /// under the working directory. Resolving also folded `muse-bin-1.0.3-R/.`
    /// down to its folder, which is what gives the old path away here.
    @Test("Reads the executable name as a string, not a file path", arguments: ["muse-bin-1.0.3-R/.", "muse-bin-1.0.3-R/sub/.."])
    func versionedBinaryCheckDoesNotResolveTheName(name: String) {
        #expect(!MuseExecutableName(name).isVersionedBinary)
    }

    @Test(
        "Still finds the versioned binary by its last path component",
        arguments: ["muse-bin-1.0.3-R", "MUSE-BIN-1.0.3-R", "./muse-bin-1.0.3-R", "/opt/muse/bin/muse-bin-1.0.3-R/"]
    )
    func versionedBinaryCheckUsesTheLastPathComponent(name: String) {
        #expect(MuseExecutableName(name).isVersionedBinary)
    }

    @Test("Replaces a prior session reference and drops one-shot launch state")
    func sanitizesCapturedLaunchArguments() {
        #expect(
            AgentResumeArgv().builtInKind(
                kind: "muse",
                sessionId: sessionId,
                executablePath: "/Users/example/.local/bin/muse",
                arguments: [
                    "/Users/example/.local/bin/muse",
                    "resume", "old-session",
                    "--model", "muse-spark",
                    "--reasoning-effort", "high",
                    "--yolo",
                ]
            ) == [
                "/Users/example/.local/bin/muse", "resume", sessionId,
                "--model", "muse-spark",
                "--reasoning-effort", "high",
                "--yolo",
            ]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "muse",
                    "--image", "/tmp/screen.png",
                    "-w", "create",
                    "--worktree-base", "main",
                    "--approval-mode", "never",
                    "initial prompt should not replay",
                ],
                launcher: "muse",
                fallbackKind: "muse"
            ) == ["muse", "--approval-mode", "never"]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["muse", "resume", "--last", "--model", "muse-spark"],
                launcher: "muse",
                fallbackKind: "muse"
            ) == ["muse", "--model", "muse-spark"]
        )
    }

    @Test("Refuses headless and management launches")
    func rejectsNonInteractiveLaunches() {
        #expect(AgentLaunchSanitizer.preservedArguments(kind: "muse", args: ["exec", "fix it"]) == nil)
        #expect(AgentLaunchSanitizer.preservedArguments(kind: "muse", args: ["plugins", "list"]) == nil)
        #expect(AgentLaunchSanitizer.preservedArguments(kind: "muse", args: ["--no-session-log"]) == nil)
    }

    @Test("Recognizes the versioned Muse binary as the Muse agent process")
    func recognizesVersionedBinaryProcess() {
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKind(
                processName: "muse-bin-1.4.6-R",
                arguments: ["/Users/example/.local/bin/muse-bin-1.4.6-R6000.1"],
                kind: "muse"
            )
        )
        #expect(
            AgentLaunchCaptureTrust.nativeProcessDescribesKnownAgent(
                processName: "muse-bin-1.4.6-R",
                arguments: ["/Users/example/.local/bin/muse-bin-1.4.6-R6000.1"]
            )
        )
    }
}
