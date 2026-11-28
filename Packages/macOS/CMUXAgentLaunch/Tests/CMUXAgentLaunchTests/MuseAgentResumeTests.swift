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
