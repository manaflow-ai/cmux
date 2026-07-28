import CMUXAgentLaunch
import Testing

@Suite("Managed launcher non-launch classification")
struct ManagedLauncherNonLaunchTests {
    private let classifier = AgentLaunchInvocationClassifier()

    @Test("OMO preserves documented management commands")
    func omoManagementCommands() {
        for command in [
            "agent", "auth", "completion", "db", "debug", "mcp", "models",
            "export", "import", "plugin", "plug", "providers", "stats", "uninstall", "upgrade",
        ] {
            #expect(classifier.omoLaunchIsNonLaunch(args: [command]))
        }
        #expect(classifier.omoLaunchIsNonLaunch(args: ["session", "list"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["session", "delete", "session-id"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--log-level", "WARN", "models"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--mdns", "models"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--port", "4096", "models"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--hostname=127.0.0.1", "models"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--mdns-domain", "local", "models"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--cors", "https://example.com", "models"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["--help"]))
        #expect(classifier.omoLaunchIsNonLaunch(args: ["-v"]))
    }

    @Test("OMO rejects sessions, unknown commands, and command-shaped values")
    func omoLaunches() {
        for args in [
            ["acp"],
            ["serve"],
            ["web"],
            ["session"],
            ["session", "run"],
            ["run", "hello"],
            ["unknown-command"],
            ["--session", "session-id"],
            ["--model", "--version"],
            ["--port", "models"],
            ["--hostname", "--version"],
            ["--mdns-domain"],
            ["--cors"],
            ["--mdns", "run", "hello"],
            ["--", "--version"],
            ["some-project"],
        ] {
            #expect(!classifier.omoLaunchIsNonLaunch(args: args))
        }
    }

    @Test("OMC preserves commands that do not start an agent or team")
    func omcManagementCommands() {
        for command in [
            "ask", "capabilities", "config", "config-notify-profile",
            "config-stop-callback", "doctor", "help", "info", "install",
            "postinstall", "session", "setup", "teleport", "test-prompt",
            "update", "update-reconcile", "version",
        ] {
            #expect(classifier.omcLaunchIsNonLaunch(args: [command]))
        }
        #expect(classifier.omcLaunchIsNonLaunch(args: ["--help"]))
        #expect(classifier.omcLaunchIsNonLaunch(args: ["--version"]))
        #expect(classifier.omcLaunchIsNonLaunch(args: ["team", "api", "claim-task"]))
        #expect(classifier.omcLaunchIsNonLaunch(args: ["team", "status", "demo"]))
        #expect(classifier.omcLaunchIsNonLaunch(args: ["team", "shutdown", "demo"]))
    }

    @Test("OMC rejects agent and team launch commands")
    func omcLaunches() {
        for args in [
            [],
            ["launch"],
            ["interop"],
            ["team"],
            ["team", "1:codex", "review this"],
            ["autoresearch"],
            ["ralphthon"],
            ["ultragoal"],
            ["start a team"],
            ["--", "version"],
        ] {
            #expect(!classifier.omcLaunchIsNonLaunch(args: args))
        }
    }

    @Test("OMX preserves documented management commands")
    func omxManagementCommands() {
        for command in [
            "agents", "agents-init", "auth", "cancel", "capabilities", "deepinit",
            "doctor", "help", "list", "session", "setup", "status", "uninstall",
            "update", "version",
        ] {
            #expect(classifier.omxLaunchIsNonLaunch(args: [command]))
        }
        #expect(classifier.omxLaunchIsNonLaunch(args: ["--help"]))
        #expect(classifier.omxLaunchIsNonLaunch(args: ["--version"]))
    }

    @Test("OMX rejects sessions, unknown commands, and command-shaped values")
    func omxLaunches() {
        for args in [
            ["resume"],
            ["team", "status", "demo"],
            ["unknown-command"],
            ["--scope", "project", "setup"],
            ["--scope", "--version"],
            ["--", "--version"],
            ["--high"],
        ] {
            #expect(!classifier.omxLaunchIsNonLaunch(args: args))
        }
    }
}
