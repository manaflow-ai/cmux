import CMUXAgentLaunch
import Testing

@Suite("Managed launcher non-launch classification")
struct ManagedLauncherNonLaunchTests {
    @Test("OMO preserves documented management commands")
    func omoManagementCommands() {
        for command in [
            "agent", "auth", "completion", "db", "debug", "mcp", "models",
            "export", "import", "plugin", "plug", "providers", "stats", "uninstall", "upgrade",
        ] {
            #expect(AgentLaunchSanitizer.omoLaunchIsNonLaunch(args: [command]))
        }
        #expect(AgentLaunchSanitizer.omoLaunchIsNonLaunch(args: ["session", "list"]))
        #expect(AgentLaunchSanitizer.omoLaunchIsNonLaunch(args: ["session", "delete", "session-id"]))
        #expect(AgentLaunchSanitizer.omoLaunchIsNonLaunch(args: ["--log-level", "WARN", "models"]))
        #expect(AgentLaunchSanitizer.omoLaunchIsNonLaunch(args: ["--help"]))
        #expect(AgentLaunchSanitizer.omoLaunchIsNonLaunch(args: ["-v"]))
    }

    @Test("OMO rejects sessions, unknown commands, and command-shaped values")
    func omoLaunches() {
        for args in [
            ["session"],
            ["session", "run"],
            ["run", "hello"],
            ["unknown-command"],
            ["--session", "session-id"],
            ["--model", "--version"],
            ["--", "--version"],
            ["some-project"],
        ] {
            #expect(!AgentLaunchSanitizer.omoLaunchIsNonLaunch(args: args))
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
            #expect(AgentLaunchSanitizer.omcLaunchIsNonLaunch(args: [command]))
        }
        #expect(AgentLaunchSanitizer.omcLaunchIsNonLaunch(args: ["--help"]))
        #expect(AgentLaunchSanitizer.omcLaunchIsNonLaunch(args: ["--version"]))
    }

    @Test("OMC rejects agent and team launch commands")
    func omcLaunches() {
        for args in [
            [],
            ["launch"],
            ["interop"],
            ["team"],
            ["autoresearch"],
            ["ralphthon"],
            ["ultragoal"],
            ["start a team"],
            ["--", "version"],
        ] {
            #expect(!AgentLaunchSanitizer.omcLaunchIsNonLaunch(args: args))
        }
    }

    @Test("OMX preserves documented management commands")
    func omxManagementCommands() {
        for command in [
            "agents", "agents-init", "auth", "cancel", "capabilities", "deepinit",
            "doctor", "help", "list", "session", "setup", "status", "uninstall",
            "update", "version",
        ] {
            #expect(AgentLaunchSanitizer.omxLaunchIsNonLaunch(args: [command]))
        }
        #expect(AgentLaunchSanitizer.omxLaunchIsNonLaunch(args: ["--scope", "project", "setup"]))
        #expect(AgentLaunchSanitizer.omxLaunchIsNonLaunch(args: ["--help"]))
        #expect(AgentLaunchSanitizer.omxLaunchIsNonLaunch(args: ["--version"]))
    }

    @Test("OMX rejects sessions, unknown commands, and command-shaped values")
    func omxLaunches() {
        for args in [
            ["resume"],
            ["team", "status", "demo"],
            ["unknown-command"],
            ["--scope", "--version"],
            ["--", "--version"],
            ["--high"],
        ] {
            #expect(!AgentLaunchSanitizer.omxLaunchIsNonLaunch(args: args))
        }
    }
}
